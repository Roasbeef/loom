//// The home page (protocol-change/065): the principal's sessions grouped by
//// workspace in the session page's frame, with a table in the centre and no
//// strand panel.
////
//// These tests pin what the page lists and in what order, that resident and
//// saved are told apart in words, that every catalogue field is drawn as
//// escaped text, that the only handlers are a running session's row beneath the
//// two regions the socket admits and that a press asks the daemon for a ticket,
//// which saved rows are presses at which ceiling and what a resume does and
//// refuses, when the page reads its list, and how a page that can no longer be
//// served ends.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/actions
import web_view/creations
import web_view/ending
import web_view/home
import web_view/page
import web_view/renames
import web_view/sessions.{type Entry, Blocked, Entry, Live, Saved}
import web_view/signins
import web_view/view/create
import web_view/view/home_table

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn entry(
  id: String,
  name: String,
  workspace: String,
  created_at: Int,
  residency: sessions.Residency,
) -> Entry {
  Entry(
    id:,
    name:,
    workspace:,
    created_at:,
    residency:,
    subtitle: None,
    role: None,
    project: None,
  )
}

// The instant the page reads the clock at: two hours and a few minutes after
// the second session was created, and long after the first.
const now = 7_400_000

// Three workspaces: `/src/weft` holds the newest session, so it comes first.
fn listing() -> List(Entry) {
  [
    entry("B", "vetting lint", "/src/loom", 300_000, Live),
    entry("A", "web ui", "/src/loom", 100_000, Live),
    entry("C", "hex release", "/src/weft", 1_790_000_000_000, Saved),
    entry("D", "", "/src/notes", 500_000, Saved),
  ]
}

fn start_with(ceiling: home.Ceiling, read: fn() -> home.Listing) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling:,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(read()) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, _) { Nil },
    rename: None,
    manage: None,
    create: None,
    folders: None,
    signins: fn(deliver) { deliver(signins.Listed([])) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self: None,
  )
}

fn start() -> home.Start {
  start_with(home.OperatorCeiling, fn() { home.Listed(listing()) })
}

// Runs one message through the component and performs its effects the way
// Lustre's runtime would: a dispatched message is applied in its turn. The
// effect's own dispatches are collected and folded back in, in order.
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

// Every message the effects dispatched is applied in order, as the runtime
// would apply them: the timer's read now answers with the list and then
// starts the sign-ins, the name and the activity reads from that answer, so a
// settle that took one message would drop the rest.
fn settle(model: home.Model, dispatched: Subject(home.Msg)) -> home.Model {
  case process.receive(dispatched, 0) {
    Ok(next) -> settle(run(model, next), dispatched)
    Error(Nil) -> model
  }
}

// A page whose timer exists and whose first read has answered.
fn opened(start: home.Start) -> #(home.Model, Subject(Nil)) {
  let timer = process.new_subject()
  #(run(home.new(start), home.TimerReady(timer)), timer)
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

// A page that has read nothing has nothing to draw but its words, and is
// still connecting.
pub fn a_new_page_has_read_nothing_test() {
  let model = home.new(start())
  assert home.groups(model) == []
  assert home.status(model) == home.Connecting
  let html = drawn(model)
  assert string.contains(html, "connecting")
  assert string.contains(html, "You hold no sessions yet.")
  assert string.contains(html, "sidebar=\"none\"")
}

// The list is read off the runtime: a read that has not answered leaves the
// page connecting with no groups, asks for no sign-ins and arms no timer,
// and the answer, when the task delivers it, lands as `Refreshed`, after
// which the sign-ins are read and the timer armed.
pub fn a_list_that_answers_late_leaves_the_page_open_test() {
  let delivery = process.new_subject()
  let signins_asked = process.new_subject()
  let #(model, timer) =
    opened(
      home.Start(
        ..start(),
        sessions: fn(deliver) { process.send(delivery, deliver) },
        signins: fn(deliver) {
          process.send(signins_asked, Nil)
          deliver(signins.Listed([]))
        },
      ),
    )
  let assert Ok(_) = process.receive(delivery, 0) as "the read was started"
  assert home.status(model) == home.Connecting
  assert home.groups(model) == []
  assert process.receive(signins_asked, 0) == Error(Nil)
  assert process.receive(timer, 20) == Error(Nil)

  let model =
    run(model, home.Refreshed(home.reads(model), home.Listed(listing())))
  assert home.status(model) == home.Connected
  assert list.length(home.groups(model)) == 3
  assert process.receive(signins_asked, 0) == Ok(Nil)
  assert process.receive(timer, 1000) == Ok(Nil)
}

// A timer read still in flight when an action reads again answers late, with
// a list older than the action's: it is dropped, so the archived row stays
// gone instead of coming back until the next tick, and it still arms the
// timer, so the cadence continues.
pub fn a_late_timer_read_is_dropped_behind_an_actions_read_test() {
  let delivery = process.new_subject()
  let ask = fn(action, _session, deliver) { deliver(actions.Done(action)) }
  let #(owner, timer) =
    opened(
      home.Start(..start(), manage: Some(ask), sessions: fn(deliver) {
        process.send(delivery, deliver)
      }),
    )

  // The open's read, the first, answers and arms the timer.
  let owner = run(owner, home.Refreshed(1, home.Listed(listing())))
  assert lists(owner, "C")
  let _ = process.receive(timer, 1000)

  // The timer fires, so the second read is out; before it answers the owner
  // archives C, and the action's answer starts the third read, which lands.
  let model = run(owner, home.Ticked)
  let model = run(model, home.ArchiveRequested("C"))
  assert home.reads(model) == 3
  let without_c = list.filter(listing(), fn(row) { row.id != "C" })
  let model = run(model, home.Answered(3, home.Listed(without_c)))
  assert !lists(model, "C")

  // The second read lands late with C still in it: dropped, and the timer
  // is armed from it all the same.
  let model = run(model, home.Refreshed(2, home.Listed(listing())))
  assert !lists(model, "C")
  assert home.reads(model) == 3
  assert process.receive(timer, 1000) == Ok(Nil)
}

// Whether the page's groups hold the session.
fn lists(model: home.Model, session: String) -> Bool {
  list.any(home.groups(model), fn(group) {
    list.any(group.entries, fn(entry) { entry.id == session })
  })
}

// The first read answers when the timer exists, the sessions are grouped by
// workspace in alphabetical order, and the sessions of a workspace run newest
// first.
pub fn the_page_lists_the_sessions_grouped_by_workspace_test() {
  let #(model, _) = opened(start())
  assert home.status(model) == home.Connected
  assert list.map(home.groups(model), fn(group) { group.workspace })
    == ["/src/loom", "/src/notes", "/src/weft"]
  let assert [loom, _, _] = home.groups(model)
  assert list.map(loom.entries, fn(entry) { entry.id }) == ["B", "A"]
}

// A session a process runs and one that is on disk are told apart in words as
// well as a glyph, and an unnamed session is named by its identity.
pub fn resident_and_saved_are_marked_in_words_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert string.contains(html, "running · created ")
  assert !string.contains(html, "resident")
  assert string.contains(html, "saved · ")
  assert string.contains(html, "Session D")
  assert string.contains(html, "vetting lint")

  // The centre is a list for each project, not a table: a heading with the
  // project's name and a count, and one item for each session.
  assert string.contains(html, "class=\"home-workspace\"")
  assert string.contains(html, ">weft<span class=\"home-count\">")
  assert !string.contains(html, "<table")
  assert !string.contains(html, "<th")
  assert list.length(string.split(html, "class=\"home-row ")) == 5
}

// The project heading is the directory's name and keeps
// the whole path in its title, with the session count beside it.
pub fn the_project_heading_is_the_name_and_counted_test() {
  let #(model, _) =
    opened(
      start_with(home.OperatorCeiling, fn() {
        home.Listed([
          entry("A", "web ui", "/Users/ada/src/loom", 1, Live),
          entry("B", "lint", "/Users/ada/src/loom", 2, Live),
        ])
      }),
    )
  let html = drawn(model)
  assert string.contains(
    html,
    "<h3 class=\"home-workspace\" title=\"/Users/ada/src/loom\">loom"
      <> "<span class=\"home-count\">2</span></h3>",
  )
}

// A row's age is counted from the clock the page read with its list, and the
// exact creation minute in UTC, from the integer alone, is the time element's
// title and datetime. A running session's age says it was created; a saved
// session's is bare after "saved".
pub fn the_creation_time_is_an_age_with_the_utc_minute_in_its_title_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert string.contains(html, "datetime=\"2026-09-21T14:13Z\"")
  assert string.contains(html, "title=\"2026-09-21 14:13 UTC\"")
  assert string.contains(html, "title=\"1970-01-01 00:08 UTC\"")
  assert string.contains(
    html,
    "running · created <time datetime=\"1970-01-01T00:05Z\""
      <> " title=\"1970-01-01 00:05 UTC\">1h ago</time>",
  )
  assert string.contains(html, "saved · <time datetime=\"1970-01-01T00:08Z\"")
  assert string.contains(html, ">2h ago</time>")

  // A creation after the page's clock is as recent as the clock can say.
  assert string.contains(html, ">just now</time>")
}

pub fn an_age_is_counted_in_whole_units_test() {
  assert sessions.ago(59_999, 0) == "just now"
  assert sessions.ago(60_000, 0) == "1m ago"
  assert sessions.ago(3_599_000, 0) == "59m ago"
  assert sessions.ago(3_600_000, 0) == "1h ago"
  assert sessions.ago(86_399_000, 0) == "23h ago"
  assert sessions.ago(86_400_000, 0) == "1d ago"
  assert sessions.ago(2_591_999_000, 0) == "29d ago"
  assert sessions.ago(2_592_000_000, 0) == "over a month ago"
  assert sessions.ago(0, 5000) == "just now"
}

// A row says what its running session is doing, in the words the daemon's
// state gave, once the daemon has answered; before that, and for a session the
// daemon could not ask, it says only that the session is running. The activity
// word stands in for "running" and does not follow it. A saved session has no
// activity, whatever a stale answer says.
pub fn a_running_row_says_what_it_is_doing_test() {
  let asked = process.new_subject()
  let #(model, _) =
    opened(
      home.Start(..start(), activity: fn(ids, deliver) {
        process.send(asked, ids)
        deliver([
          #("B", sessions.Working),
          #("A", sessions.NeedsYou),
          #("C", sessions.Idle),
        ])
      }),
    )

  // The list asked for its two running sessions, in the order drawn, and
  // never for a saved one.
  assert process.receive(asked, 0) == Ok(["B", "A"])
  let html = drawn(model)
  assert string.contains(
    html,
    "<span class=\"home-activity\">working</span> · created ",
  )
  assert string.contains(
    html,
    "<span class=\"home-activity\">needs you</span> · created ",
  )
  assert string.contains(html, "home-row working")
  assert string.contains(html, "home-row needs-you")
  assert !string.contains(html, "idle")
  assert !string.contains(html, "saved · idle")

  // Before the answer, a running row shows only that it is running.
  let before =
    drawn(run(
      home.new(start()),
      home.Answered(home.reads(home.new(start())), home.Listed(listing())),
    ))
  assert string.contains(before, "running · created ")
  assert !string.contains(before, "working")
}

// Every answer replaces the last, so a session that went idle says so and one
// that stopped running leaves the words behind.
pub fn an_activity_answer_replaces_the_last_test() {
  let #(model, _) = opened(start())
  let model =
    run(model, home.Observed([#("B", sessions.Working), #("A", sessions.Idle)]))
  assert string.contains(
    drawn(model),
    "<span class=\"home-activity\">idle</span> · created ",
  )
  let model = run(model, home.Observed([#("B", sessions.Idle)]))
  assert !string.contains(drawn(model), "working")

  // The sidebar says the same word, so count the list's activity spans only.
  assert list.length(string.split(drawn(model), "home-activity\">idle<")) == 2
}

// The activity word is a span of its own, so a needs-you row can tint that word
// and leave the rest of the quiet line, which holds the session's first prompt,
// in the quiet colour. The subtitle sits outside the span.
pub fn the_activity_word_is_its_own_span_test() {
  let subtitled =
    list.map(listing(), fn(row) {
      case row.id {
        "A" -> Entry(..row, subtitle: Some("Fix the flaky retry test"))
        _ -> row
      }
    })
  let #(model, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(subtitled) }))
  let model = run(model, home.Observed([#("A", sessions.NeedsYou)]))
  let html = drawn(model)
  assert string.contains(
    html,
    "<span class=\"home-subtitle\">Fix the flaky retry test</span> · <span class=\"home-activity\">needs you</span>",
  )
  assert list.length(string.split(html, "home-activity")) == 2

  // A saved row has no activity and so no span.
  assert !string.contains(html, "saved · <span class=\"home-activity")
}

// The daemon's own bound is the page's: no more running sessions than
// `activity_limit` are named in one read, the first ones in the order drawn,
// and a page with no running session asks nothing.
pub fn the_activity_read_is_bounded_and_skips_a_page_with_nothing_running_test() {
  let asked = process.new_subject()
  let ask = fn(ids, _) { process.send(asked, ids) }
  let many =
    list.repeat(Nil, sessions.activity_limit + 6)
    |> list.index_map(fn(_, index) {
      let n = index + 1
      entry(string.inspect(n), "s", "/src/x", 1000 * n, Live)
    })
  let _ =
    opened(
      home.Start(
        ..start_with(home.OperatorCeiling, fn() { home.Listed(many) }),
        activity: ask,
      ),
    )
  let assert Ok(ids) = process.receive(asked, 0)
  assert list.length(ids) == sessions.activity_limit
  assert list.first(ids) == Ok(string.inspect(sessions.activity_limit + 6))

  let _ =
    opened(
      home.Start(
        ..start_with(home.OperatorCeiling, fn() {
          home.Listed([entry("C", "saved", "/src/x", 1, Saved)])
        }),
        activity: ask,
      ),
    )
  assert process.receive(asked, 0) == Error(Nil)
}

// An ended page asks for no activity, and keeps the words it had.
pub fn an_ended_page_asks_for_no_activity_test() {
  let asked = process.new_subject()
  let #(model, _) =
    opened(
      home.Start(..start(), activity: fn(ids, _) { process.send(asked, ids) }),
    )
  let _ = process.receive(asked, 0)
  let ended =
    run(
      model,
      home.Answered(home.reads(model), home.Closed(ending.AccessRevoked)),
    )
  let ended = run(ended, home.Observed([#("B", sessions.Working)]))
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(ended), "working")
}

// The daemon's state words map to activities, and a word the page does not
// know is no activity.
pub fn the_daemons_state_words_are_total_test() {
  assert sessions.activity_of("needs_you") == Ok(sessions.NeedsYou)
  assert sessions.activity_of("working") == Ok(sessions.Working)
  assert sessions.activity_of("idle") == Ok(sessions.Idle)
  assert sessions.activity_of("unknown") == Error(Nil)
  assert sessions.activity_of("") == Error(Nil)
  assert sessions.activity_of("<script>") == Error(Nil)
  assert sessions.activity_words(sessions.NeedsYou) == "needs you"
}

// The list's pressable rows are buttons that fill the item, and a row that is
// text has no button, so a hover tint is drawn only where a press works.
pub fn a_row_is_a_button_only_where_a_press_works_test() {
  let #(observer, _) =
    opened(start_with(home.ObserverCeiling, fn() { home.Listed(listing()) }))
  let html = drawn(observer)
  assert string.contains(html, "<button class=\"home-open\"")
  assert string.contains(html, "class=\"home-item\"")
  assert string.contains(
    html,
    "<span aria-hidden=\"true\" class=\"home-chevron\">",
  )
}

// The bar is the session page's: the status is the same pill, coloured by the
// page's standing, and the principal and ceiling are plain text spans with no
// monospaced class.
pub fn the_bar_matches_the_session_pages_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert string.contains(html, "class=\"status pill online\"")
  let connecting = drawn(home.new(start()))
  assert string.contains(connecting, "class=\"status pill pending\"")
  let ended =
    drawn(run(
      model,
      home.Answered(home.reads(model), home.Closed(ending.AccessRevoked)),
    ))
  assert string.contains(ended, "class=\"status pill ended\"")
  assert !string.contains(html, "mono")
}

pub fn the_clock_is_civil_utc_test() {
  assert home_table.utc(0) == #("1970-01-01", "00:00")
  assert home_table.utc(-5) == #("1970-01-01", "00:00")
  assert home_table.utc(951_782_400_000) == #("2000-02-29", "00:00")
  assert home_table.utc(1_709_251_199_000) == #("2024-02-29", "23:59")
  assert home_table.utc(1_709_251_200_000) == #("2024-03-01", "00:00")
  assert home_table.utc(4_102_444_800_000) == #("2100-01-01", "00:00")
}

// Names and paths are the catalogue's, drawn as text and never as markup.
pub fn the_page_escapes_what_the_catalogue_holds_test() {
  let hostile = [
    entry("A", "<b>bold</b> & co", "/src/<x>", 1, Live),
    entry("F", "<script>alert(1)</script>", "/src/<x>", 2, Saved),
  ]
  let #(model, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(hostile) }))
  let html = drawn(model)
  assert !string.contains(html, "<b>bold")
  assert !string.contains(html, "<script")
  assert string.contains(html, "&lt;b&gt;bold&lt;/b&gt; &amp; co")
  assert string.contains(html, "&lt;script&gt;")
  assert string.contains(html, "/src/&lt;x&gt;")
}

// On a page minted to read, two running sessions, `A` and `B`, are the only
// rows with a press: each is a button in the table and another in the sidebar,
// so four handlers in all, each a click beneath one of the two regions the
// daemon's socket admits. A saved session's row is text, and nothing is a link
// or a form.
pub fn an_observer_homes_only_running_rows_carry_a_press_test() {
  let #(observer, _) =
    opened(start_with(home.ObserverCeiling, fn() { home.Listed(listing()) }))
  let keys = handlers(home.view(observer))
  assert list.length(keys) == 4
  assert list.all(keys, beneath_the_two_regions)
  assert list.length(
      list.filter(keys, string.starts_with(_, home.table_path <> "\t")),
    )
    == 2
  let html = element.to_string(home.view(observer))
  assert list.length(string.split(html, "<button")) == 7
  assert !string.contains(html, "<a ")
  assert !string.contains(html, "<form")
  assert !string.contains(html, "href")
}

fn beneath_the_two_regions(key: String) -> Bool {
  string.ends_with(key, "\nclick")
  && {
    string.starts_with(key, home.table_path <> "\t")
    || string.starts_with(key, home.sidebar_path <> "\t")
  }
}

// On a page minted to operate, the two saved sessions `C` and `D` are presses
// too, in the table and in the sidebar, beneath the same two regions, so the
// socket admits nothing new. A session that is `Blocked` is text at either
// ceiling.
pub fn an_operator_home_presses_saved_rows_too_test() {
  let with_blocked = [
    entry("E", "stuck", "/src/notes", 1, Blocked),
    ..listing()
  ]
  let #(operator, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(with_blocked) }))
  let keys = handlers(home.view(operator))
  assert list.length(keys) == 8
  assert list.all(keys, beneath_the_two_regions)
  let html = element.to_string(home.view(operator))
  assert list.length(string.split(html, "<button")) == 11
  assert string.contains(html, "title=\"Resume this session\"")
  assert string.contains(html, "stuck")

  let #(observer, _) =
    opened(start_with(home.ObserverCeiling, fn() { home.Listed(with_blocked) }))
  assert list.length(handlers(home.view(observer))) == 4
}

// A resume press hands the session to the daemon's task and returns: the row
// reads "Opening…", no saved row has a press while it is out, and a second press
// asks nothing, even one that names another saved row.
pub fn a_resume_marks_its_row_and_a_second_press_asks_nothing_test() {
  let asked = process.new_subject()
  let #(model, _) =
    opened(home.Start(..start(), resume: fn(id, _) { process.send(asked, id) }))
  let model = run(model, home.Resuming("C"))
  assert process.receive(asked, 0) == Ok("C")
  let html = drawn(model)
  assert string.contains(html, "opening")
  assert string.contains(html, "Opening…")

  // Only the two running rows keep a press, in each region.
  assert list.length(handlers(home.view(model))) == 4

  let model = run(model, home.Resuming("D"))
  let model = run(model, home.Resuming("C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert list.length(handlers(home.view(model))) == 4
}

// The task's answer arrives as a message from the task's own process: a ticket
// becomes the address the hidden element navigates to and leaves the row saying
// "Opening…" until the page goes, and a refusal is the reason's fixed words,
// beside the row, with the presses restored.
pub fn the_tasks_answer_departs_or_words_the_refusal_test() {
  let ticket = "/ui/sessions/C?ticket=t"
  let #(model, _) =
    opened(
      home.Start(..start(), resume: fn(_, deliver) {
        deliver(sessions.Ticketed(ticket))
      }),
    )
  let model = run(model, home.Resuming("C"))
  let html = drawn(model)
  assert string.contains(html, "to=\"" <> ticket <> "\"")
  assert string.contains(html, "Opening…")
  assert list.length(handlers(home.view(model))) == 4

  let #(model, _) =
    opened(
      home.Start(..start(), resume: fn(_, deliver) {
        deliver(sessions.Declined(sessions.NotOpened))
      }),
    )
  let model = run(model, home.Resuming("C"))
  let html = drawn(model)
  assert string.contains(html, sessions.reason_words(sessions.NotOpened))
  assert !string.contains(html, "Opening…")
  assert !string.contains(html, " to=")
  assert list.length(handlers(home.view(model))) == 8
}

// A page minted to read has no resume to ask for, even if a frame named a
// saved row: the update drops the message. A page that ended asks nothing
// either.
pub fn a_resume_is_dropped_on_an_observer_or_ended_page_test() {
  let asked = process.new_subject()
  let ask = fn(id, _) { process.send(asked, id) }
  let #(observer, _) =
    opened(
      home.Start(
        ..start_with(home.ObserverCeiling, fn() { home.Listed(listing()) }),
        resume: ask,
      ),
    )
  let observer = run(observer, home.Resuming("C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(observer), "Opening that session")

  let #(operator, _) = opened(home.Start(..start(), resume: ask))
  let ended =
    run(
      operator,
      home.Answered(home.reads(operator), home.Closed(ending.AccessRevoked)),
    )
  let ended = run(ended, home.Resuming("C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(ended), "Opening that session")
}

// A press asks the daemon to open the row's session in the component's own
// process, and a ticket becomes the address the hidden element navigates to.
pub fn a_press_asks_for_a_ticket_and_the_answer_is_the_address_test() {
  let asked = process.new_subject()
  let ticket = "/ui/sessions/A?ticket=t"
  let #(model, _) =
    opened(
      home.Start(..start(), open: fn(id) {
        process.send(asked, id)
        sessions.Ticketed(ticket)
      }),
    )
  let model = run(model, home.Opening("A"))
  assert process.receive(asked, 0) == Ok("A")
  let html = drawn(model)
  assert string.contains(html, "to=\"" <> ticket <> "\"")
  assert string.contains(html, "<loom-switch hidden")

  // The pressed row says so until the page goes, and a second press asks
  // nothing.
  assert string.contains(html, "Opening…")
  assert string.contains(html, "home-row opening")
  let again = run(model, home.Opening("B"))
  assert process.receive(asked, 0) == Error(Nil)
  assert drawn(again) == html
}

// The keyboard switcher is the centre's last child on the home, after the
// switch element, so no admitted path moves for it, and it carries nothing the
// server wrote.
pub fn the_session_switcher_follows_the_switch_element_test() {
  let #(model, _) = opened(start())
  assert string.contains(
    drawn(model),
    "<loom-switch hidden></loom-switch><loom-switcher></loom-switcher></main>",
  )
}

// A refusal is worded in the reason's fixed words, draws no address, and
// leaves the page connected.
pub fn a_refusal_is_fixed_words_and_no_address_test() {
  let #(model, _) =
    opened(
      home.Start(..start(), open: fn(_) {
        sessions.Declined(sessions.NotRunning)
      }),
    )
  let model = run(model, home.Opening("A"))
  let html = drawn(model)
  assert string.contains(html, sessions.reason_words(sessions.NotRunning))
  assert !string.contains(html, " to=")
  assert home.status(model) == home.Connected
}

// A page that ended asks for nothing.
pub fn an_ended_page_asks_for_no_ticket_test() {
  let asked = process.new_subject()
  let #(model, _) =
    opened(
      home.Start(..start(), open: fn(id) {
        process.send(asked, id)
        sessions.Ticketed("/ui/sessions/A?ticket=t")
      }),
    )
  let model =
    run(
      model,
      home.Answered(home.reads(model), home.Closed(ending.AccessRevoked)),
    )
  let model = run(model, home.Opening("A"))
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(model), " to=")
}

// The notice's place is always drawn, so the table keeps its path whether or
// not a press has been answered.
pub fn the_table_keeps_its_path_with_and_without_a_notice_test() {
  let #(model, _) =
    opened(
      home.Start(..start(), open: fn(_) { sessions.Declined(sessions.NotHeld) }),
    )
  let before = handlers(home.view(model))
  let after = handlers(home.view(run(model, home.Opening("A"))))
  assert before == after
}

// The frame is the session page's, and the home's: a "Home" entry leads the
// sidebar and is the page on screen, no row is current, and the strand panel
// is not drawn.
pub fn the_frame_is_the_session_pages_without_a_panel_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert string.starts_with(html, "<loom-shell")
  assert string.contains(html, "loom-session loom-home")
  assert string.contains(html, "sidebar=\"listed\"")
  assert string.contains(
    html,
    "<aside aria-label=\"Sessions\" class=\"sidebar\"",
  )
  assert string.contains(
    html,
    "<p aria-current=\"page\" class=\"sidebar-home\"><svg",
  )
  assert string.contains(html, "</svg>Home</p>")
  assert !string.contains(html, "aria-current=\"true\"")
  assert !string.contains(html, "Strand panel")

  // The sidebar draws the same sessions as the table: every name appears
  // twice, once in each.
  assert list.length(string.split(html, "vetting lint")) == 3
}

// The top bar says whose page this is and the most it may do, in fixed words.
pub fn the_bar_names_the_principal_and_the_ceiling_test() {
  let #(operator, _) = opened(start())
  let html = drawn(operator)
  assert string.contains(html, "<h1>Home</h1>")
  assert string.contains(html, ">Alice<")
  assert string.contains(html, ">connected<")

  // An operating page may do all its principal may, which is the normal case,
  // so the bar says nothing beside the name.
  assert !string.contains(html, "home-badge")
  assert !string.contains(html, ">operator<")
  let #(observer, _) =
    opened(start_with(home.ObserverCeiling, fn() { home.Listed([]) }))
  let watching = drawn(observer)
  assert string.contains(watching, ">read-only link<")
  assert string.contains(watching, "title=\"This link can only watch\"")
}

// The timer is armed when the page opens and again after each read, so the
// list is read at the interval and not before.
pub fn the_list_is_read_at_the_interval_test() {
  let reads = process.new_subject()
  let #(model, timer) =
    opened(
      start_with(home.OperatorCeiling, fn() {
        process.send(reads, Nil)
        home.Listed(listing())
      }),
    )
  assert process.receive(reads, 0) == Ok(Nil)
  assert process.receive(reads, 0) == Error(Nil)
  assert process.receive(timer, 1000) == Ok(Nil)

  // The timer fires as a tick: another read, and another arming.
  let model = run(model, home.Ticked)
  assert process.receive(reads, 0) == Ok(Nil)
  assert process.receive(timer, 1000) == Ok(Nil)
  assert home.status(model) == home.Connected
}

// A read the registry did not answer changes nothing the page shows and does
// not end it.
pub fn an_unread_list_keeps_the_last_one_test() {
  let #(model, _) = opened(start())
  let model = run(model, home.Answered(home.reads(model), home.Unread))
  assert home.status(model) == home.Connected
  assert list.length(home.groups(model)) == 3

  // A page that never read stays connecting.
  let fresh =
    run(
      home.new(start()),
      home.Answered(home.reads(home.new(start())), home.Unread),
    )
  assert home.status(fresh) == home.Connecting
}

// A list replaces the last: a session that is gone is gone from the page.
pub fn a_new_list_replaces_the_old_one_test() {
  let #(model, _) = opened(start())
  let model =
    run(
      model,
      home.Answered(
        home.reads(model),
        home.Listed([entry("A", "web ui", "/src/loom", 1, Live)]),
      ),
    )
  assert list.map(home.groups(model), fn(group) { group.workspace })
    == ["/src/loom"]
  assert !string.contains(drawn(model), "hex release")
}

// A page that can no longer be served draws why, in the home's own words that
// name no session, keeps the last list beside the notice, and asks for
// nothing more: no read and no timer after it.
pub fn a_closed_page_draws_its_ending_and_reads_no_more_test() {
  let reads = process.new_subject()
  let #(model, timer) =
    opened(
      start_with(home.OperatorCeiling, fn() {
        process.send(reads, Nil)
        home.Listed(listing())
      }),
    )
  let _ = process.receive(reads, 0)
  let _ = process.receive(timer, 1000)
  let model =
    run(
      model,
      home.Answered(home.reads(model), home.Closed(ending.AccessRevoked)),
    )
  assert home.status(model) == home.Ended(ending.AccessRevoked)
  let html = drawn(model)
  assert string.contains(html, ">disconnected<")
  assert string.contains(html, "Your access was revoked or changed.")
  assert string.contains(html, "Run loom ui for a fresh link.")
  assert !string.contains(html, "--session")
  assert string.contains(html, "hex release")

  let model = run(model, home.Ticked)
  assert home.status(model) == home.Ended(ending.AccessRevoked)
  assert process.receive(reads, 0) == Error(Nil)
  assert process.receive(timer, 20) == Error(Nil)

  // The read that answers `Closed` is itself the last: it arms no timer, so
  // no tick follows it to ask again.
  let #(model, timer) =
    opened(
      start_with(home.OperatorCeiling, fn() {
        home.Closed(ending.AccessRevoked)
      }),
    )
  assert home.status(model) == home.Ended(ending.AccessRevoked)
  assert process.receive(timer, 50) == Error(Nil)
}

// The page keeps at most the catalogue's first page of sessions.
pub fn a_list_past_the_limit_is_cut_test() {
  let many =
    list.repeat(Nil, sessions.listed_limit + 20)
    |> list.index_map(fn(_, n) {
      entry(string.inspect(n), "s", "/src/x", n, Saved)
    })
  let #(model, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(many) }))
  let assert [group] = home.groups(model)
  assert list.length(group.entries) == sessions.listed_limit
}

// --- the documents around the page ------------------------------------------

pub fn the_home_has_its_own_addresses_test() {
  assert page.home_path("abc") == "/ui/p/abc/home"
  assert page.home_exchange_path("t") == "/ui/home?ticket=t"
}

// The home's shell is the session page's, loading the same scripts under the
// same policy, with its own title and a waiting paragraph that names `loom ui`
// and no session.
pub fn the_home_shell_names_no_session_test() {
  let shell = page.home_shell()
  assert string.contains(shell, "<title>Home — Loom</title>")
  assert string.contains(shell, "<lustre-server-component>")
  assert string.contains(shell, page.asset_path(page.page_asset))
  assert string.contains(shell, page.asset_path(page.client_asset))
  assert string.contains(shell, "run loom ui for a fresh link")
  assert !string.contains(shell, "--session")
}

pub fn a_refused_home_names_no_session_test() {
  list.each(ending.all(), fn(reason) {
    let refusal = page.home_refusal(reason)
    assert string.contains(refusal, "role=\"alert\"")
    assert string.contains(refusal, "subject=\"link\" text=\"loom ui\"")
    assert !string.contains(refusal, "--session")

    // The only script is the page's own client bundle.
    assert list.length(string.split(refusal, "<script")) == 2
  })
}

// Every ending has words for a home, and none says "session" where the home
// has none to be revoked from or to stop.
pub fn every_ending_has_home_words_test() {
  list.each(ending.all(), fn(reason) {
    assert ending.home_headline(reason) != ""
    assert string.contains(ending.home_advice(reason), "loom ui")
    assert !string.contains(ending.home_headline(reason), "session")
  })
  assert ending.home_headline(ending.AccessRevoked)
    == "Your access was revoked or changed."
}

// The first prompt's first line leads a session's quiet line in place of its
// age (protocol-change/067): the subtitle, then the standing's words. A session
// with none keeps the age it always had, and the subtitle is only ever a text
// node.
pub fn a_subtitle_leads_the_quiet_line_in_place_of_the_age_test() {
  let subtitled =
    list.map(listing(), fn(row) {
      case row.id {
        "B" -> Entry(..row, subtitle: Some("Fix the flaky retry test"))
        "C" -> Entry(..row, subtitle: Some("Port the parser"))
        _ -> row
      }
    })
  let #(model, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(subtitled) }))
  let html = drawn(model)
  assert string.contains(
    html,
    "<span class=\"home-subtitle\">Fix the flaky retry test</span> · running",
  )
  assert string.contains(
    html,
    "<span class=\"home-subtitle\">Port the parser</span> · saved",
  )

  // A and D have no subtitle, so they read as before.
  assert string.contains(html, "running · created ")
  assert string.contains(html, "saved · <time")
  assert list.length(string.split(html, "home-subtitle")) == 3
}

pub fn a_subtitle_is_never_an_attribute_test() {
  let hostile = "\"><img src=x onerror=alert(1)>"
  let rows = [
    Entry(
      ..entry("A", "web ui", "/src/loom", 100, Live),
      subtitle: Some(hostile),
    ),
  ]
  let #(model, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(rows) }))
  let html = drawn(model)
  assert !string.contains(html, "<img")
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")

  // The table and the sidebar both draw it, each time as escaped text.
  assert list.length(string.split(html, "onerror"))
    == list.length(string.split(html, "onerror=alert(1)&gt;"))
  assert !string.contains(html, "title=\"" <> hostile)
}

// An owner's home draws a Rename button after each row's own button, so the
// row's handler keeps its place, and the new handlers are clicks beneath the
// region the socket already admits. Without the capability the page is as it
// was: no button, no form.
pub fn an_owners_home_draws_a_rename_button_after_each_row_test() {
  let ask = fn(_session, _name, _deliver) { Nil }
  let #(owner, _) = opened(home.Start(..start(), rename: Some(ask)))
  let html = drawn(owner)
  assert list.length(string.split(html, "class=\"home-rename\"")) == 5
  assert string.contains(html, "renamable")
  assert !string.contains(html, "<form")

  let with = handlers(home.view(owner))
  let #(member, _) = opened(start())
  let without = handlers(home.view(member))
  assert list.length(with) == list.length(without) + 4
  assert list.all(with, beneath_the_two_regions)

  // Every handler a member's page has is on the owner's page at the same path.
  assert list.all(without, fn(key) { list.contains(with, key) })

  // The row's own handler is the item's, first in the row; the buttons are in
  // one group, the second child, so no existing path moved. Rename is the
  // group's first button.
  let added = list.filter(with, fn(key) { !list.contains(without, key) })
  assert list.length(added) == 4
  assert list.all(added, fn(key) {
    string.starts_with(key, home.table_path <> "\t")
    && string.ends_with(key, "\t1\t0\nclick")
  })

  let plain = drawn(member)
  assert !string.contains(plain, "home-rename")
  assert !string.contains(plain, "<form")
}

// A press on a row's Rename opens that row's form in place of its words: the
// current name is a text node in the lead, the field carries none of it, and the
// handlers beneath the table are the form's submit and the Cancel button.
pub fn pressing_rename_opens_that_rows_form_test() {
  let ask = fn(_session, _name, _deliver) { Nil }
  let #(owner, _) = opened(home.Start(..start(), rename: Some(ask)))
  let model = run(owner, home.EditRequested("B"))
  let html = drawn(model)
  assert string.contains(html, "home-rename-form")
  assert string.contains(
    html,
    "Rename <span data-loom-name>vetting lint</span>",
  )
  assert string.contains(html, "data-loom-renames")
  assert string.contains(html, "<loom-rename><input")
  assert string.contains(html, "name=\"text\"")
  assert !string.contains(html, "value=\"vetting lint")
  assert !string.contains(html, " value=")
  assert !string.contains(html, "placeholder=\"vetting lint")
  assert list.length(string.split(html, "<form")) == 2

  let keys = handlers(home.view(model))
  let submits = list.filter(keys, string.ends_with(_, "\nsubmit"))
  assert list.length(submits) == 1
  assert list.all(submits, string.starts_with(_, home.table_path <> "\t"))
  assert list.all(
    list.filter(keys, fn(key) { !string.ends_with(key, "\nsubmit") }),
    beneath_the_two_regions,
  )

  // Opening another row's form closes this one: one form at a time.
  let model = run(model, home.EditRequested("A"))
  let html = drawn(model)
  assert list.length(string.split(html, "<form")) == 2
  assert string.contains(html, "Rename <span data-loom-name>web ui</span>")
  assert !string.contains(
    html,
    "Rename <span data-loom-name>vetting lint</span>",
  )

  let model = run(model, home.EditCancelled)
  assert !string.contains(drawn(model), "<form")
}

// A submit asks the daemon once, for the row whose form is open, and the
// daemon's answer becomes the row's name and the page's notice.
pub fn a_submit_asks_once_and_the_answer_names_the_row_test() {
  let asked = process.new_subject()
  let ask = fn(session, name, deliver) {
    process.send(asked, #(session, name))
    deliver(renames.Renamed("review auth"))
  }
  let #(owner, _) = opened(home.Start(..start(), rename: Some(ask)))
  let model = run(owner, home.EditRequested("B"))
  let model = run(model, home.Renaming("B", "review auth"))
  assert process.receive(asked, 0) == Ok(#("B", "review auth"))
  assert process.receive(asked, 0) == Error(Nil)
  let html = drawn(model)
  assert string.contains(html, "review auth")
  assert !string.contains(html, "vetting lint")
  assert string.contains(html, "Renamed.")
  assert !string.contains(html, "<form")
}

// While a request is out a second submit asks nothing; a submit for a row whose
// form is not open asks nothing either, so a frame cannot name another session.
pub fn a_second_or_forged_submit_asks_nothing_test() {
  let asked = process.new_subject()
  let ask = fn(session, name, _deliver) {
    process.send(asked, #(session, name))
  }
  let #(owner, _) = opened(home.Start(..start(), rename: Some(ask)))

  // No form is open, so nothing is asked, whichever session is named.
  let model = run(owner, home.Renaming("A", "x"))
  assert process.receive(asked, 0) == Error(Nil)

  // The form of B is open: a submit naming A is dropped, and B's goes through
  // once.
  let model = run(model, home.EditRequested("B"))
  let model = run(model, home.Renaming("A", "forged"))
  assert process.receive(asked, 0) == Error(Nil)
  let model = run(model, home.Renaming("B", "first"))
  let model = run(model, home.Renaming("B", "second"))
  assert process.receive(asked, 0) == Ok(#("B", "first"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "disabled")

  // The form cannot be closed or moved while the request is out.
  let model = run(model, home.EditCancelled)
  let model = run(model, home.EditRequested("A"))
  assert string.contains(
    drawn(model),
    "Rename <span data-loom-name>vetting lint</span>",
  )
}

// A page the daemon handed no capability ignores every rename message: it draws
// no form and asks nothing.
pub fn a_page_without_the_capability_ignores_rename_messages_test() {
  let #(member, _) = opened(start())
  let model = run(member, home.EditRequested("B"))
  let model = run(model, home.Renaming("B", "x"))
  assert !string.contains(drawn(model), "<form")
  assert drawn(model) == drawn(member)
}

// A refusal is worded in the reason's fixed words inside the open form, which
// stays open so the name can be corrected.
pub fn a_refusal_is_worded_in_the_open_form_test() {
  let ask = fn(_session, _name, deliver) {
    deliver(renames.Declined(renames.InvalidName))
  }
  let #(owner, _) = opened(home.Start(..start(), rename: Some(ask)))
  let model = run(owner, home.EditRequested("B"))
  let model = run(model, home.Renaming("B", "bad"))
  let html = drawn(model)
  assert string.contains(html, renames.reason_words(renames.InvalidName))
  assert string.contains(html, "<form")
  assert string.contains(html, "vetting lint")
}

// An answer nobody asked for is dropped: no daemon message changes a name unless
// a request is out.
pub fn an_unsolicited_rename_answer_is_dropped_test() {
  let ask = fn(_session, _name, _deliver) { Nil }
  let #(owner, _) = opened(home.Start(..start(), rename: Some(ask)))
  let model = run(owner, home.RenameAnswered(renames.Renamed("forged")))
  assert drawn(model) == drawn(owner)
}

// ---------------------------------------------------------------------------
// Creating a session (protocol-change/065, the fourth pull request).
// ---------------------------------------------------------------------------

// A page that may create: the owner's, minted to operate. `ask` is what the
// daemon's task does with the request, and the page's own state is what the
// tests read.
fn creator(
  ask: fn(
    creations.Place,
    String,
    creations.Sharing,
    fn(creations.Answer) -> Nil,
  ) -> Nil,
) -> home.Start {
  home.Start(..start(), create: Some(ask))
}

fn recording(
  asked: Subject(#(creations.Place, String, creations.Sharing)),
) -> fn(creations.Place, String, creations.Sharing, fn(creations.Answer) -> Nil) ->
  Nil {
  fn(place, name, sharing, _) { process.send(asked, #(place, name, sharing)) }
}

// A member's page and an observer-ceiling page have no capability, so they draw
// no button, no form and no field, and the messages that would open or send one
// change nothing and ask nothing.
pub fn a_page_without_the_capability_draws_no_creation_control_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert !string.contains(html, "New session")
  assert !string.contains(html, "<form")
  assert !string.contains(html, "<input")
  assert !string.contains(html, "<label")

  let model = run(model, home.Choosing("/src/loom"))
  let model =
    run(model, home.Creating("/src/loom", "name", creations.Shareable))
  assert drawn(model) == html
  assert list.length(handlers(home.view(model))) == 8
}

// The owner's page has one button under each workspace, one more for another
// folder (protocol-change/074), and no form until a button is pressed. The new handlers are clicks beneath the table, which the
// socket already admits, and the sidebar and the table keep their own.
pub fn the_owner_has_a_button_under_each_workspace_test() {
  let asked = process.new_subject()
  let #(model, _) = opened(creator(recording(asked)))
  let html = drawn(model)
  assert list.length(string.split(html, "class=\"home-new\"")) == 5
  assert !string.contains(html, "<form")
  let keys = handlers(home.view(model))
  assert list.length(keys) == 12
  assert list.all(keys, beneath_the_two_regions)
}

// A press opens the form under its workspace only. The form is one name field,
// one checkbox and two buttons, its submit is the one new event kind and sits
// beneath the table, and nothing about the workspace or a name is an attribute.
pub fn a_press_opens_one_form_under_its_workspace_test() {
  let asked = process.new_subject()
  let #(model, _) = opened(creator(recording(asked)))
  let model = run(model, home.Choosing("/src/loom"))
  let html = drawn(model)
  assert list.length(string.split(html, "<form")) == 2
  assert string.contains(html, "name=\"name\"")
  assert string.contains(html, "name=\"shareable\"")
  assert string.contains(html, "type=\"checkbox\"")
  assert string.contains(html, "Create session")
  assert string.contains(html, "Left blank, the session is named <b>loom</b>.")
  assert process.receive(asked, 0) == Error(Nil)

  // The form's submit and its Cancel are beneath the table.
  let keys = handlers(home.view(model))
  let submits = list.filter(keys, string.ends_with(_, "\nsubmit"))
  assert list.length(submits) == 1
  assert list.all(submits, string.starts_with(_, home.table_path <> "\t"))
  assert list.all(keys, string.starts_with(_, "0\t"))

  // Another workspace's button moves the form, and Cancel closes it.
  let moved = run(model, home.Choosing("/src/weft"))
  assert string.contains(drawn(moved), "named <b>weft</b>.")
  assert !string.contains(drawn(moved), "named <b>loom</b>.")
  let closed = run(moved, home.Cancelled)
  assert !string.contains(drawn(closed), "<form")
}

// A submit asks the daemon once, with the workspace the form was drawn under,
// and the page then waits: the form is disabled, no button has a press, and a
// second submit asks nothing.
pub fn a_submit_asks_once_and_the_page_waits_test() {
  let asked = process.new_subject()
  let #(model, _) = opened(creator(recording(asked)))
  let model = run(model, home.Choosing("/src/loom"))
  let model =
    run(model, home.Creating("/src/loom", "review", creations.Shareable))
  assert process.receive(asked, 0)
    == Ok(#(creations.Drawn("/src/loom"), "review", creations.Shareable))
  let html = drawn(model)
  assert string.contains(html, "Creating</button>")
  assert string.contains(html, "disabled")

  let again =
    run(model, home.Creating("/src/loom", "second", creations.Private))
  let elsewhere = run(model, home.Choosing("/src/weft"))
  let _ = run(elsewhere, home.Creating("/src/weft", "third", creations.Private))
  assert process.receive(asked, 0) == Error(Nil)
  assert drawn(again) == html
}

// A submit is honoured only for the form that is open: with no form, or for
// another workspace's, nothing is asked.
pub fn a_submit_for_a_form_that_is_not_open_asks_nothing_test() {
  let asked = process.new_subject()
  let #(model, _) = opened(creator(recording(asked)))
  let _ = run(model, home.Creating("/src/loom", "x", creations.Private))
  let open = run(model, home.Choosing("/src/loom"))
  let _ = run(open, home.Creating("/src/weft", "x", creations.Private))
  assert process.receive(asked, 0) == Error(Nil)
}

// The answer arrives from the task: a ticket departs for the new session and
// closes the form, and a refusal is the reason's fixed words with the form back
// for a correction, except for a session that was made and did not open.
pub fn the_answer_departs_or_words_the_refusal_test() {
  let ticket = "/ui/sessions/N?ticket=t"
  let #(model, _) =
    opened(
      creator(fn(_, _, _, deliver) { deliver(creations.Ticketed(ticket)) }),
    )
  let model = run(model, home.Choosing("/src/loom"))
  let model = run(model, home.Creating("/src/loom", "", creations.Private))
  let html = drawn(model)
  assert string.contains(html, "to=\"" <> ticket <> "\"")
  assert !string.contains(html, "<form")

  let refuse = fn(reason) {
    let #(model, _) =
      opened(
        creator(fn(_, _, _, deliver) { deliver(creations.Declined(reason)) }),
      )
    let model = run(model, home.Choosing("/src/loom"))
    run(model, home.Creating("/src/loom", "", creations.Private))
  }
  let invalid = drawn(refuse(creations.InvalidName))
  assert string.contains(invalid, creations.reason_words(creations.InvalidName))
  assert string.contains(invalid, "<form")
  assert !string.contains(invalid, " to=")

  let unopened = drawn(refuse(creations.NotOpened))
  assert string.contains(unopened, creations.reason_words(creations.NotOpened))
  assert !string.contains(unopened, "<form")
}

// What the browser's submit lists is decoded totally: one name, at most one
// checkbox that reads `on`, and no other field.
pub fn the_form_fields_decode_totally_test() {
  assert create.fields([#("name", "review")])
    == Ok(#("review", creations.Private))
  assert create.fields([#("name", ""), #("shareable", "on")])
    == Ok(#("", creations.Shareable))
  assert create.fields([#("shareable", "on"), #("name", "x")])
    == Ok(#("x", creations.Shareable))
  assert create.fields([]) == Error(Nil)
  assert create.fields([#("shareable", "on")]) == Error(Nil)
  assert create.fields([#("name", "a"), #("name", "b")]) == Error(Nil)
  assert create.fields([#("name", "a"), #("shareable", "yes")]) == Error(Nil)
  assert create.fields([#("name", "a"), #("workspace", "/etc")]) == Error(Nil)
  assert create.fields([#("name", "a"), #("shareable", "on"), #("x", "y")])
    == Error(Nil)
}

// The one rule for a name: trimmed, blank means the folder's name, a bound in
// bytes, and no text the page would change.
pub fn a_name_is_trimmed_bounded_and_clean_test() {
  assert creations.chosen_name("  review  ", "/src/loom") == Ok("review")
  assert creations.chosen_name("", "/src/loom") == Ok("loom")
  assert creations.chosen_name("   ", "/src/loom/") == Ok("loom")
  assert creations.chosen_name("a\nb", "/src/loom") == Error(Nil)
  assert creations.chosen_name("a\u{202e}b", "/src/loom") == Error(Nil)
  assert creations.chosen_name("a\u{200b}b", "/src/loom") == Error(Nil)
  assert creations.chosen_name(string.repeat("a", 256), "/w")
    == Ok(string.repeat("a", 256))
  assert creations.chosen_name(string.repeat("a", 257), "/w") == Error(Nil)
  assert creations.chosen_name("", "/") == Ok("New session")
  assert creations.folder("/") == "New session"
}

// Every reason has its own fixed words, and none carries text from the daemon.
pub fn every_creation_refusal_has_its_own_words_test() {
  let reasons = [
    creations.NotOwner,
    creations.NotKnown,
    creations.InvalidName,
    creations.TooMany,
    creations.Full,
    creations.NotOpened,
    creations.Unavailable,
    creations.NotAFolder,
    creations.OutsideHome,
    creations.HomeItself,
    creations.HiddenFolder,
    creations.StateFolder,
  ]
  let words = list.map(reasons, creations.reason_words)
  assert list.length(list.unique(words)) == 12
}

// A workspace, a name or a folder from the catalogue is a text node: it is
// escaped, and it is not in any attribute of the form, whose placeholder and
// labels are fixed words.
pub fn the_form_draws_the_workspace_only_as_text_test() {
  let hostile = "/src/<script>alert(1)</script>"
  let #(model, _) =
    opened(
      home.Start(..creator(fn(_, _, _, _) { Nil }), sessions: fn(deliver) {
        deliver(home.Listed([entry("Z", "x", hostile, 1, Live)]))
      }),
    )
  let model = run(model, home.Choosing(hostile))
  let html = drawn(model)
  assert !string.contains(html, "<script>")
  assert string.contains(html, "&lt;script&gt;")
  assert string.contains(html, "placeholder=\"Session name (optional)\"")
  assert !string.contains(html, "value=")
}

// The owner's home has two forms that submit, a row's rename and a workspace's
// creation, and the socket admits a submit by path alone. A submit reaches the
// handler drawn at its own path, so the two must sit at different paths, and
// each decoder must refuse the other's fields: the rename form sends one field
// named `text` and the creation form sends `name` and at most `shareable`. Each
// message changes only its own form's state.
pub fn the_rename_and_creation_forms_cannot_be_confused_test() {
  let asked = process.new_subject()
  let renamed = process.new_subject()
  let #(model, _) =
    opened(
      home.Start(
        ..creator(recording(asked)),
        rename: Some(fn(session, name, _) {
          process.send(renamed, #(session, name))
        }),
      ),
    )
  let model = run(model, home.EditRequested("B"))
  let model = run(model, home.Choosing("/src/weft"))
  let submits =
    list.filter(handlers(home.view(model)), string.ends_with(_, "\nsubmit"))
  assert list.length(submits) == 2
  assert list.length(list.unique(submits)) == 2
  assert list.all(submits, string.starts_with(_, home.table_path <> "\t"))

  // The decoders refuse each other's fields.
  assert create.fields([#("text", "a name")]) == Error(Nil)
  assert create.fields([#("name", "a name"), #("text", "x")]) == Error(Nil)

  // A rename changes nothing about the creation form, and the reverse.
  let after_rename = run(model, home.Renaming("B", "new name"))
  assert process.receive(renamed, 0) == Ok(#("B", "new name"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(after_rename), "named <b>weft</b>.")

  let after_create =
    run(model, home.Creating("/src/weft", "made", creations.Private))
  assert process.receive(asked, 0)
    == Ok(#(creations.Drawn("/src/weft"), "made", creations.Private))
  assert process.receive(renamed, 0) == Error(Nil)
  assert string.contains(drawn(after_create), "Creating</button>")
}

// --- the owner's "Admin" button (protocol-change/065, the fifth pull request) --

const admin_ticket =
  "/ui/admin?ticket=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// A page that was handed the capability, whose request answers with `answer` at
// once and tells `asked` that it was made.
fn administrator(asked: Subject(Nil), answer: sessions.Answer) -> home.Start {
  home.Start(
    ..start(),
    admin: Some(fn(deliver) {
      process.send(asked, Nil)
      deliver(answer)
    }),
  )
}

// The button exists only on a page whose daemon handed it the capability, and
// only once the page is connected. Its one handler is a click at the path the
// owner's socket admits and no other, in the bar, beneath neither region the
// other controls are in.
pub fn the_admin_button_is_drawn_only_with_the_capability_test() {
  let asked = process.new_subject()
  let #(owner, _) =
    opened(administrator(asked, sessions.Ticketed(admin_ticket)))
  let html = drawn(owner)
  assert string.contains(html, "home-admin")
  assert string.contains(html, ">Admin<")
  let keys = handlers(home.view(owner))
  let at_the_button = list.filter(keys, string.starts_with(_, home.admin_path))
  assert at_the_button == [home.admin_path <> "\nclick"]
  assert !beneath_the_two_regions(home.admin_path <> "\nclick")

  // A page with none draws no button and carries no handler at the path.
  let #(plain, _) = opened(start())
  assert !string.contains(drawn(plain), "home-admin")
  assert !string.contains(drawn(plain), ">Admin<")
  assert list.filter(handlers(home.view(plain)), string.starts_with(
      _,
      home.admin_path,
    ))
    == []

  // And a page that has read nothing, or whose access ended, draws none.
  let waiting = home.new(home.Start(..start(), admin: Some(fn(_) { Nil })))
  assert !string.contains(drawn(waiting), "home-admin")
  let ended =
    run(
      owner,
      home.Answered(home.reads(owner), home.Closed(ending.AccessRevoked)),
    )
  assert !string.contains(drawn(ended), "home-admin")
}

// The path is where the view puts it: the bar's sixth child, which the socket
// pins. The brand, the title, the principal, the status and the notice's place
// come before it, so adding the button moved none of them.
pub fn the_admin_buttons_path_is_the_bars_last_child_test() {
  assert home.admin_path == "0\t0\t5"
  let asked = process.new_subject()
  let #(owner, _) =
    opened(administrator(asked, sessions.Ticketed(admin_ticket)))
  assert list.contains(handlers(home.view(owner)), home.admin_path <> "\nclick")

  // The regions the other admissions pin are where they were.
  assert home.table_path == "0\t2\t1"
  assert home.sidebar_path == "0\t1"
}

// A press asks the daemon once, and the ticket it answers with departs through
// the hidden element that moves the tab, with a notice that says what is
// happening. A refusal is the reason's fixed words and nothing departs.
pub fn pressing_admin_asks_the_daemon_and_departs_with_its_ticket_test() {
  let asked = process.new_subject()
  let #(owner, _) =
    opened(administrator(asked, sessions.Ticketed(admin_ticket)))
  let owner = run(owner, home.AdminRequested)
  assert process.receive(asked, 0) == Ok(Nil)
  assert process.receive(asked, 0) == Error(Nil)
  let html = drawn(owner)
  assert string.contains(html, "to=\"" <> admin_ticket <> "\"")

  let refused = process.new_subject()
  let #(denied, _) =
    opened(administrator(refused, sessions.Declined(sessions.NoAdmin)))
  let denied = run(denied, home.AdminRequested)
  let html = drawn(denied)
  assert string.contains(html, sessions.reason_words(sessions.NoAdmin))
  assert !string.contains(html, "to=\"/ui/admin")
}

// A page with no capability ignores the message whatever sends it, so a forged
// press asks nothing: the page's half of the rule the daemon enforces again.
pub fn a_page_without_the_capability_ignores_the_admin_press_test() {
  let #(plain, _) = opened(start())
  let pressed = run(plain, home.AdminRequested)
  assert !string.contains(drawn(pressed), "to=\"/ui/admin")

  // A page still connecting, or already ended, asks nothing even with it.
  let asked = process.new_subject()
  let offered = administrator(asked, sessions.Ticketed(admin_ticket))
  let waiting = run(home.new(offered), home.AdminRequested)
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(waiting), "to=\"/ui/admin")
  let #(owner, _) = opened(offered)
  let ended =
    run(
      run(
        owner,
        home.Answered(home.reads(owner), home.Closed(ending.PageEnded)),
      ),
      home.AdminRequested,
    )
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(ended), "to=\"/ui/admin")
}

// An unnamed session's label is a fallback built from its identity, not a name.
// Its lead is drawn without the marker `<loom-rename>` copies from, so the field
// opens empty and Enter cannot save the fallback as the name.
pub fn an_unnamed_rows_form_has_no_name_to_copy_test() {
  let ask = fn(_session, _name, _deliver) { Nil }
  let #(owner, _) = opened(home.Start(..start(), rename: Some(ask)))
  let html = drawn(run(owner, home.EditRequested("D")))
  assert string.contains(html, "home-rename-form")
  assert string.contains(html, "Rename Session D")
  assert !string.contains(html, "data-loom-name")
}

// Each row's quiet line carries the person's role in that session after the
// state word, for a member. The owner's rows, which have no role, read as they
// did. The role is the membership's, so the words are the two fixed ones.
pub fn a_members_rows_say_the_role_they_hold_test() {
  let rows = [
    Entry(
      ..entry("B", "vetting lint", "/src/loom", 300_000, Live),
      role: Some(sessions.Observes),
    ),
    Entry(
      ..entry("A", "web ui", "/src/loom", 100_000, Live),
      role: Some(sessions.Operates),
    ),
    entry("C", "hex release", "/src/weft", 1_790_000_000_000, Saved),
  ]
  let #(model, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(rows) }))
  let html = drawn(model)
  assert string.contains(html, "running · observer")
  assert string.contains(html, "running · operator")
  assert list.length(string.split(html, "· observer")) == 2
  assert list.length(string.split(html, "· operator")) == 2
  let #(owner, _) = opened(start())
  let owned = drawn(owner)
  assert !string.contains(owned, "observer")
  assert !string.contains(owned, "· operator")
}

// The sidebar says what the list says: a running row's word is the activity
// read's answer, "needs you" in the signal hue, and nothing until the read has
// answered. The words "saved" stay.
pub fn the_sidebar_says_the_activity_word_the_list_says_test() {
  let #(model, _) =
    opened(
      home.Start(..start(), activity: fn(_, deliver) {
        deliver([#("B", sessions.Working), #("A", sessions.NeedsYou)])
      }),
    )
  let html = drawn(model)
  assert string.contains(
    html,
    "<span aria-hidden=\"true\" class=\"glyph\">●</span>working</span>",
  )
  assert string.contains(
    html,
    "<span aria-hidden=\"true\" class=\"glyph\">●</span>needs you</span>",
  )
  assert string.contains(html, "residency live needs-you")

  // Before the answer, a running row's suffix is empty rather than "running".
  let before =
    drawn(run(
      home.new(start()),
      home.Answered(home.reads(home.new(start())), home.Listed(listing())),
    ))
  assert string.contains(
    before,
    "<span aria-hidden=\"true\" class=\"glyph\">●</span></span>",
  )
  assert !string.contains(before, ">●</span>running")
  assert string.contains(before, ">○</span>saved")
}

// The owner's fresh home draws the actions that fit each row: Stop on a running
// session, Archive and Delete on a saved one. Every handler it adds is a click
// beneath the region the socket already admits, and every handler the page had
// without the capability is still at its own path.
pub fn the_owners_fresh_home_draws_the_actions_that_fit_each_row_test() {
  let ask = fn(_action, _session, _deliver) { Nil }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let html = drawn(owner)

  // Two running rows and two saved ones.
  assert list.length(string.split(html, ">Stop<")) == 3
  assert list.length(string.split(html, ">Archive<")) == 3
  assert list.length(string.split(html, ">Delete<")) == 3
  assert string.contains(html, "actionable")
  assert !string.contains(html, "Delete this session? This cannot be undone.")

  let #(plain, _) = opened(start())
  let with = handlers(home.view(owner))
  let without = handlers(home.view(plain))
  assert list.length(with) == list.length(without) + 10
  assert list.all(with, beneath_the_two_regions)
  assert list.all(without, fn(key) { list.contains(with, key) })

  let html = drawn(plain)
  assert !string.contains(html, ">Stop<")
  assert !string.contains(html, ">Archive<")
  assert !string.contains(html, "home-act")
}

// A press on Stop asks the daemon once, for the row it was drawn on, and the
// daemon's answer is the page's notice. While the request is out a second press
// asks nothing.
pub fn a_stop_asks_once_and_the_answer_is_the_notice_test() {
  let asked = process.new_subject()
  let ask = fn(action, session, deliver) {
    process.send(asked, #(action, session))
    deliver(actions.Done(action))
  }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let model = run(owner, home.StopRequested("B"))
  assert process.receive(asked, 0) == Ok(#(actions.Stop, "B"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "Stopped.")

  let silent = fn(action, session, _deliver) {
    process.send(asked, #(action, session))
  }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(silent)))
  let model = run(owner, home.ArchiveRequested("C"))
  let model = run(model, home.ArchiveRequested("D"))
  let model = run(model, home.StopRequested("A"))
  assert process.receive(asked, 0) == Ok(#(actions.Archive, "C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "disabled")
}

// Delete is two presses. The first replaces the row's words with the question
// and sends nothing; Cancel puts the row back; the second, for the same row,
// asks once. A confirmation for another row, or with none open, asks nothing.
pub fn a_delete_asks_only_after_the_rows_confirmation_test() {
  let asked = process.new_subject()
  let ask = fn(action, session, _deliver) {
    process.send(asked, #(action, session))
  }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))

  let model = run(owner, home.DeleteConfirmed("C"))
  assert process.receive(asked, 0) == Error(Nil)

  let model = run(model, home.DeleteRequested("C"))
  let html = drawn(model)
  assert string.contains(html, "Delete this session? This cannot be undone.")
  assert list.length(string.split(html, "This cannot be undone.")) == 2
  assert process.receive(asked, 0) == Error(Nil)

  let model = run(model, home.ConfirmCancelled)
  assert !string.contains(drawn(model), "This cannot be undone.")

  let model = run(model, home.DeleteRequested("C"))
  let model = run(model, home.DeleteConfirmed("D"))
  assert process.receive(asked, 0) == Error(Nil)
  let model = run(model, home.DeleteConfirmed("C"))
  assert process.receive(asked, 0) == Ok(#(actions.Delete, "C"))
  let model = run(model, home.DeleteConfirmed("C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "disabled")
}

// A refusal is the reason's fixed words, whatever the daemon had to say.
pub fn a_refused_action_says_the_fixed_words_test() {
  let ask = fn(_action, _session, deliver) {
    deliver(actions.Declined(actions.Running))
  }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let model = run(owner, home.ArchiveRequested("C"))
  assert string.contains(drawn(model), actions.reason_words(actions.Running))
  assert actions.reason_words(actions.Running)
    == "That session is still running. Stop it first."
}

// A page the daemon handed no capability draws no button and ignores every
// message of the actions, an answer nobody asked for included.
pub fn a_page_without_the_capability_ignores_the_actions_test() {
  let #(member, _) = opened(start())
  let model = run(member, home.StopRequested("B"))
  let model = run(model, home.ArchiveRequested("C"))
  let model = run(model, home.DeleteRequested("C"))
  let model = run(model, home.DeleteConfirmed("C"))
  let model = run(model, home.ActionAnswered(actions.Done(actions.Delete)))
  assert drawn(model) == drawn(member)

  let ask = fn(_action, _session, _deliver) { Nil }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let model = run(owner, home.ActionAnswered(actions.Done(actions.Delete)))
  assert drawn(model) == drawn(owner)
}

// The confirmation names the row it replaced, as a text node: a hostile name is
// escaped there as everywhere, and the question itself is fixed words.
pub fn the_confirmation_names_its_row_as_text_test() {
  let hostile = "<img src=x onerror=alert(1)>"
  let ask = fn(_action, _session, _deliver) { Nil }
  let #(owner, _) =
    opened(
      home.Start(..start(), manage: Some(ask), sessions: fn(deliver) {
        deliver(home.Listed([entry("C", hostile, "/src/weft", 1, Saved)]))
      }),
    )
  let model = run(owner, home.DeleteRequested("C"))
  let html = drawn(model)
  assert string.contains(html, "Delete this session? This cannot be undone.")
  assert string.contains(
    html,
    "<p class=\"home-confirm-name\">&lt;img src=x onerror=alert(1)&gt;</p>",
  )
  assert !string.contains(html, "<img src=x onerror")
}

// A blocked row (an unreconciled creation, or a recovery that stopped) says
// "needs attention" with a fixed title, never "saved", and draws Archive and
// Delete on the owner's fresh home and nothing else: a stop has nothing to end.
// A home with no manage capability draws it as text.
pub fn a_blocked_row_draws_archive_and_delete_test() {
  let ask = fn(_action, _session, _deliver) { Nil }
  let listed = fn(deliver) {
    deliver(home.Listed([entry("X", "stuck", "/src/weft", 1, Blocked)]))
  }
  let #(owner, _) =
    opened(home.Start(..start(), manage: Some(ask), sessions: listed))
  let html = drawn(owner)
  assert string.contains(html, "stuck")
  assert string.contains(html, "needs attention")
  assert string.contains(html, "title=\"This session was never finished")
  assert !string.contains(html, ">Stop<")
  assert list.length(string.split(html, ">Archive<")) == 2
  assert list.length(string.split(html, ">Delete<")) == 2

  let #(plain, _) = opened(home.Start(..start(), sessions: listed))
  let html = drawn(plain)
  assert string.contains(html, "needs attention")
  assert !string.contains(html, ">Archive<")
  assert !string.contains(html, ">Delete<")
  assert !string.contains(html, "home-act")
}

// --- Stop asks first on a busy row (round 5, F110) ---------------------------

// A page whose manage capability records what the daemon is asked, and whose
// activity read says B is working and A needs the person.
fn busy_owner(asked: Subject(#(actions.Action, String))) -> home.Model {
  let ask = fn(action, session, _deliver) {
    process.send(asked, #(action, session))
  }
  let #(owner, _) =
    opened(
      home.Start(..start(), manage: Some(ask), activity: fn(_, deliver) {
        deliver([#("B", sessions.Working), #("A", sessions.NeedsYou)])
      }),
    )
  owner
}

// A press on Stop for a working row, or one waiting for the person, replaces the
// row's words with the question and sends nothing. Cancel puts the row back; a
// confirmation for another row asks nothing; the confirmation for that row asks
// once. The row is in a neutral tint and not the danger one.
pub fn a_stop_on_a_busy_row_asks_first_test() {
  let asked = process.new_subject()
  let owner = busy_owner(asked)

  let model = run(owner, home.StopRequested("B"))
  let html = drawn(model)
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(html, "Stop this session mid-turn?")
  assert string.contains(html, "confirm-stop")
  assert !string.contains(html, "confirm-delete")
  assert !string.contains(html, "This cannot be undone.")

  let model = run(model, home.ConfirmCancelled)
  assert !string.contains(drawn(model), "mid-turn")

  let model = run(model, home.StopRequested("B"))
  let model = run(model, home.StopConfirmed("A"))
  assert process.receive(asked, 0) == Error(Nil)
  let model = run(model, home.StopConfirmed("B"))
  assert process.receive(asked, 0) == Ok(#(actions.Stop, "B"))
  assert string.contains(drawn(model), "disabled")

  // A row that needs the person asks first too.
  let model = run(owner, home.StopRequested("A"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "Stop this session mid-turn?")
}

// An idle row, and one the activity read has not named, stops at once, with no
// question.
pub fn a_stop_on_an_idle_row_acts_at_once_test() {
  let asked = process.new_subject()
  let ask = fn(action, session, _deliver) {
    process.send(asked, #(action, session))
  }
  let #(owner, _) =
    opened(
      home.Start(..start(), manage: Some(ask), activity: fn(_, deliver) {
        deliver([#("A", sessions.Idle)])
      }),
    )
  let model = run(owner, home.StopRequested("A"))
  assert process.receive(asked, 0) == Ok(#(actions.Stop, "A"))
  assert !string.contains(drawn(model), "mid-turn")

  let _ = run(owner, home.StopRequested("B"))
  assert process.receive(asked, 0) == Ok(#(actions.Stop, "B"))
}

// A confirmation acts only for the row and the action that are confirming. One
// with nothing open, one for the other action, and one for another row ask
// nothing, so a crafted event cannot skip the question.
pub fn a_forged_confirmation_asks_nothing_test() {
  let asked = process.new_subject()
  let owner = busy_owner(asked)

  let model = run(owner, home.StopConfirmed("B"))
  let model = run(model, home.DeleteConfirmed("B"))
  assert process.receive(asked, 0) == Error(Nil)
  assert drawn(model) == drawn(owner)

  // While a stop is confirming, a Delete confirmation is not it.
  let model = run(owner, home.StopRequested("B"))
  let model = run(model, home.DeleteConfirmed("B"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "Stop this session mid-turn?")

  // And while a delete is confirming, a Stop confirmation is not it.
  let model = run(owner, home.DeleteRequested("C"))
  let model = run(model, home.StopConfirmed("C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "Delete this session?")
}

// --- Notes: where a said or refused action is drawn (round 5, F102) -----------

// A completed action is a quiet line in the row it acted on and the list's
// shape does not change: the row is the same row with a note at the end of its
// words, and the old boxed notice is gone.
pub fn a_completed_action_is_a_note_in_its_row_test() {
  let ask = fn(action, _session, deliver) { deliver(actions.Done(action)) }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let model = run(owner, home.StopRequested("B"))
  let html = drawn(model)
  assert string.contains(html, "home-note")
  assert string.contains(html, "Stopped.")
  assert !string.contains(html, "home-notice")
  assert list.length(string.split(html, "<li"))
    == list.length(string.split(drawn(owner), "<li"))
}

// When the row is gone the note is in its workspace's heading line and names
// the session, so a deletion says which one.
pub fn a_note_for_a_vanished_row_names_it_in_the_heading_test() {
  let ask = fn(action, _session, deliver) { deliver(actions.Done(action)) }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let model = run(owner, home.ArchiveRequested("C"))
  let without_c = list.filter(listing(), fn(row) { row.id != "C" })
  let model =
    run(model, home.Answered(home.reads(model), home.Listed(without_c)))
  let html = drawn(model)
  assert string.contains(html, "hex release archived.")
  assert string.contains(html, "notice-line")
  assert !string.contains(html, "home-notice")
}

// A refusal stays, in the row, in the reason's fixed words.
pub fn a_refusal_stays_beside_its_row_test() {
  let ask = fn(_action, _session, deliver) {
    deliver(actions.Declined(actions.Running))
  }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let model = run(owner, home.ArchiveRequested("C"))
  let html = drawn(model)
  assert string.contains(html, "home-note refused")
  assert string.contains(html, actions.reason_words(actions.Running))
  assert !string.contains(html, "home-notice")
}

// --- The resumed home says why it has no controls (round 5, F101) --------------

// The owner's home that a bookmark resumed has a rename capability and no
// manage or device one: its popover ends with the sentence and a copy box for
// `loom ui`. A fresh home and a member's home do not.
pub fn a_resumed_home_says_how_to_get_the_controls_test() {
  let ask = fn(_action, _session, _deliver) { Nil }
  let rename = fn(_session, _name, _deliver) { Nil }
  let device = fn() { signins.Declined(signins.NotFresh) }

  let #(resumed, _) = opened(home.Start(..start(), rename: Some(rename)))
  let html = drawn(resumed)
  assert string.contains(html, "This page was opened from a bookmark.")
  assert string.contains(html, "subject=\"link\"")
  assert string.contains(html, "text=\"loom ui\"")

  let #(fresh, _) =
    opened(
      home.Start(
        ..start(),
        rename: Some(rename),
        manage: Some(ask),
        device: Some(device),
      ),
    )
  assert !string.contains(drawn(fresh), "opened from a bookmark")

  let #(member, _) = opened(start())
  assert !string.contains(drawn(member), "opened from a bookmark")
}

// --- Review fixes: keyed rows and an opening row's actions --------------------

// Rows are keyed by session identity, so a row's handler paths do not depend on
// its position. When the row above is archived, every handler the next row had
// is at the path it had before, and a press in flight for the old position can
// not land on the row that moved up. Every handler stays beneath the table.
pub fn a_rows_handlers_do_not_move_when_a_row_above_goes_test() {
  let ask = fn(_action, _session, _deliver) { Nil }
  let #(owner, _) = opened(home.Start(..start(), manage: Some(ask)))
  let before = handlers(home.view(owner))

  // B is the first row of its workspace and A the second.
  let without_b = list.filter(listing(), fn(row) { row.id != "B" })
  let after_model =
    run(owner, home.Answered(home.reads(owner), home.Listed(without_b)))
  let after = handlers(home.view(after_model))
  let table_only =
    list.filter(after, string.starts_with(_, home.table_path <> "\t"))
  assert table_only != []
  assert list.all(table_only, fn(key) { list.contains(before, key) })
}

// A row whose open is out draws no actions, and an action pressed for it asks
// nothing, so Stop and Rename cannot be pressed on a row that is opening.
pub fn an_opening_row_offers_no_actions_test() {
  let asked = process.new_subject()
  let ask = fn(action, session, _deliver) {
    process.send(asked, #(action, session))
  }
  let rename = fn(_session, _name, _deliver) { Nil }
  let #(owner, _) =
    opened(
      home.Start(
        ..start(),
        manage: Some(ask),
        rename: Some(rename),
        open: fn(_) { sessions.Ticketed("/ui/sessions/A?ticket=t") },
      ),
    )
  let idle = drawn(owner)
  let model = run(owner, home.Opening("A"))
  let html = drawn(model)
  assert string.contains(html, "Opening…")
  assert list.length(string.split(html, ">Stop<"))
    == list.length(string.split(idle, ">Stop<")) - 1

  let model = run(model, home.StopRequested("A"))
  let model = run(model, home.DeleteRequested("A"))
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(model), "mid-turn")
}

// The home groups by project as the sidebar does: the sessions of a
// repository's worktrees share one heading, named for the repository, with the
// repository's whole path as its title. A worktree's row leads its quiet line
// with the worktree's directory name, whose title is the worktree's path, and
// the repository's own checkout row says nothing extra.
pub fn the_home_groups_by_project_and_names_the_worktree_test() {
  let tree = "/src/btcd/.claude/worktrees/hungry-euclid-d93364"
  let rows = [
    Entry(
      ..entry("A", "web ui", "/src/btcd", 1, Live),
      project: Some("/src/btcd"),
    ),
    Entry(..entry("B", "lint", tree, 2, Live), project: Some("/src/btcd")),
  ]
  let #(model, _) =
    opened(start_with(home.OperatorCeiling, fn() { home.Listed(rows) }))
  let html = drawn(model)
  assert string.contains(
    html,
    "<h3 class=\"home-workspace\" title=\"/src/btcd\">btcd"
      <> "<span class=\"home-count\">2</span></h3>",
  )
  assert !string.contains(
    html,
    ">hungry-euclid-d93364<span class=\"home-count\"",
  )
  assert string.contains(
    html,
    "<span class=\"home-tree\" title=\""
      <> tree
      <> "\">hungry-euclid-d93364</span> · ",
  )
  assert list.length(string.split(html, "home-tree")) == 2
}

// Each running row's dot class follows what the session is doing, in the
// sidebar: working and idle and needs-you each have a class of their own, which
// the stylesheet hues and pulses, and a session the read has not named has
// none beyond `live`.
pub fn the_sidebar_dot_class_follows_the_activity_test() {
  let #(model, _) = opened(start())
  let model =
    run(model, home.Observed([#("B", sessions.Working), #("A", sessions.Idle)]))
  let html = drawn(model)
  assert string.contains(html, "residency live working")
  assert string.contains(html, "residency live idle")
  assert !string.contains(html, "residency live needs-you")
  let model = run(model, home.Observed([#("A", sessions.NeedsYou)]))
  assert string.contains(drawn(model), "residency live needs-you")
}

// F142: the owner's home that a bookmark resumed has Rename and no capability to
// manage, and says in one sentence why Admin, Stop, Archive and Delete are
// missing. A fresh home, which has them, and a member's home, which never does,
// say nothing of it.
pub fn a_bookmarks_home_says_why_it_has_no_session_actions_test() {
  let ask = fn(_session, _name, _deliver) { Nil }
  let sentence = "This page was opened from a bookmark, so Admin, Stop, Archive"

  let #(resumed, _) = opened(home.Start(..start(), rename: Some(ask)))
  let html = drawn(resumed)
  assert string.contains(html, sentence)
  assert string.contains(html, "only on the home page that loom ui opens.")

  let manage = fn(_action, _session, _deliver) { Nil }
  let #(fresh, _) =
    opened(home.Start(..start(), rename: Some(ask), manage: Some(manage)))
  assert !string.contains(drawn(fresh), sentence)

  let #(member, _) = opened(start())
  assert !string.contains(drawn(member), sentence)
}

// ---------------------------------------------------------------------------
// A session in a folder that has none (protocol-change/074).
// ---------------------------------------------------------------------------

// A page that may create and lists the owner's remembered folders. `rows` is
// what each read answers, `asked` hears each creation, and `forgotten` hears
// each forget, which answers with `after`.
fn folder_keeper(
  rows: List(creations.Recent),
  asked: Subject(#(creations.Place, String, creations.Sharing)),
  forgotten: Subject(Int),
  after: List(creations.Recent),
) -> home.Start {
  home.Start(
    ..creator(recording(asked)),
    folders: Some(
      home.Folders(
        recent: fn(deliver) { deliver(rows) },
        forget: fn(id, deliver) {
          process.send(forgotten, id)
          deliver(after)
        },
      ),
    ),
  )
}

fn recent(id: Int, path: String) -> creations.Recent {
  creations.Recent(id:, path:)
}

// The control and the section exist only on a page that may create. A member's
// or an observer-ceiling page draws neither the control nor the list, and the
// messages that would open the form, send it or forget a folder change nothing
// and ask nothing.
pub fn only_a_page_that_may_create_draws_the_folder_section_test() {
  let #(plain, _) = opened(start())
  let html = drawn(plain)
  assert !string.contains(html, "another folder")
  assert !string.contains(html, "Other folders")
  assert !string.contains(html, "Forget this folder")

  let model = run(plain, home.OpeningElsewhere)
  let model =
    run(model, home.CreatingElsewhere("~/code/app", "", creations.Private))
  let model = run(model, home.Forgetting(1))
  let model = run(model, home.FoldersRead([recent(1, "/home/o/app")]))
  assert drawn(model) == html

  let asked = process.new_subject()
  let #(owner, _) = opened(creator(recording(asked)))
  assert string.contains(drawn(owner), "New session in another folder")
  assert string.contains(drawn(owner), "Other folders")
}

// A page that has not read its list yet draws no section, so the control does
// not appear before the page knows where it stands.
pub fn the_folder_section_waits_for_the_first_list_test() {
  let asked = process.new_subject()
  let model = home.new(creator(recording(asked)))
  assert !string.contains(drawn(model), "another folder")
}

// The remembered folders that no group shows are drawn, each with a button to
// start a session there and one to forget the folder. A folder a group already
// shows is not repeated.
pub fn remembered_folders_without_a_group_are_listed_test() {
  let asked = process.new_subject()
  let forgotten = process.new_subject()
  let rows = [
    recent(7, "/home/o/archived-app"),
    recent(6, "/src/loom"),
    recent(5, "/home/o/old"),
  ]
  let #(model, _) = opened(folder_keeper(rows, asked, forgotten, rows))
  let html = drawn(model)
  assert string.contains(html, "archived-app")
  assert string.contains(html, "/home/o/archived-app")
  assert string.contains(html, "/home/o/old")
  assert list.length(string.split(html, "Forget this folder")) == 3

  // `/src/loom` has a group, so it appears once as that group's heading and its
  // path is not repeated as a remembered folder.
  assert !string.contains(html, "<span class=\"home-folder-path\">/src/loom")

  // The rows are keyed by the daemon's identity and each one's buttons are
  // beneath the table, which the socket admits.
  let keys = handlers(home.view(model))
  assert list.all(keys, string.starts_with(_, "0\t"))
  assert list.any(keys, fn(key) { string.contains(key, "\tf7\t") })
  assert list.any(keys, fn(key) { string.contains(key, "\tf5\t") })
  assert process.receive(asked, 0) == Error(Nil)
}

// A folder's button opens the usual form under that folder, and its submit asks
// for the folder the tree was drawn with, as a place the page drew.
pub fn a_remembered_folder_opens_the_usual_form_test() {
  let asked = process.new_subject()
  let forgotten = process.new_subject()
  let rows = [recent(7, "/home/o/archived-app")]
  let #(model, _) = opened(folder_keeper(rows, asked, forgotten, rows))
  let model = run(model, home.Choosing("/home/o/archived-app"))
  let html = drawn(model)
  assert string.contains(html, "name=\"name\"")
  assert !string.contains(html, "name=\"path\"")
  assert string.contains(html, "named <b>archived-app</b>.")

  let model =
    run(
      model,
      home.Creating("/home/o/archived-app", "again", creations.Shareable),
    )
  assert process.receive(asked, 0)
    == Ok(#(
      creations.Drawn("/home/o/archived-app"),
      "again",
      creations.Shareable,
    ))
  assert string.contains(drawn(model), "Creating</button>")
}

// The control opens one form with a path field, the same name and the same box.
// Its submit asks for the typed path once and the form is locked while it is
// out; a second submit, and a submit while a workspace's form is open, ask
// nothing.
pub fn the_typed_folder_form_asks_once_test() {
  let asked = process.new_subject()
  let forgotten = process.new_subject()
  let #(model, _) = opened(folder_keeper([], asked, forgotten, []))
  let _ =
    run(model, home.CreatingElsewhere("~/code/app", "", creations.Private))
  assert process.receive(asked, 0) == Error(Nil)

  let model = run(model, home.OpeningElsewhere)
  let html = drawn(model)
  assert list.length(string.split(html, "<form")) == 2
  assert string.contains(html, "name=\"path\"")
  assert string.contains(html, "name=\"name\"")
  assert string.contains(html, "name=\"shareable\"")
  assert string.contains(html, "inside your home directory")
  let submits =
    list.filter(handlers(home.view(model)), string.ends_with(_, "\nsubmit"))
  assert list.length(submits) == 1
  assert list.all(submits, string.starts_with(_, home.table_path <> "\t"))

  let sent =
    run(model, home.CreatingElsewhere("~/code/app", "app", creations.Shareable))
  assert process.receive(asked, 0)
    == Ok(#(creations.Typed("~/code/app"), "app", creations.Shareable))
  assert string.contains(drawn(sent), "Creating</button>")

  let again =
    run(sent, home.CreatingElsewhere("~/code/other", "", creations.Private))
  assert process.receive(asked, 0) == Error(Nil)
  assert drawn(again) == drawn(sent)

  // A workspace's form closes the typed one, and its submit is the only one.
  let moved = run(model, home.Choosing("/src/loom"))
  assert !string.contains(drawn(moved), "name=\"path\"")
  let _ = run(moved, home.CreatingElsewhere("~/x", "", creations.Private))
  assert process.receive(asked, 0) == Error(Nil)
}

// A refusal is the reason's fixed words under the section's heading, with the form
// back for a correction, and nothing the owner typed is drawn again, in text or
// in an attribute. A session that was made and did not open closes the form.
pub fn a_refused_folder_says_why_and_never_the_path_test() {
  let typed = "~/<script>alert(1)</script>/secret-folder"
  let refuse = fn(reason) {
    let ask = fn(_, _, _, deliver) { deliver(creations.Declined(reason)) }
    let #(model, _) = opened(creator(ask))
    let model = run(model, home.OpeningElsewhere)
    run(model, home.CreatingElsewhere(typed, "", creations.Private))
  }
  let outside = drawn(refuse(creations.OutsideHome))
  assert string.contains(outside, creations.reason_words(creations.OutsideHome))
  assert string.contains(outside, "name=\"path\"")
  assert !string.contains(outside, "secret-folder")
  assert !string.contains(outside, "<script>alert")
  assert !string.contains(outside, "value=")

  let missing = drawn(refuse(creations.NotAFolder))
  assert string.contains(missing, creations.reason_words(creations.NotAFolder))

  // The refusal is drawn under the heading row, not inside it, where a long
  // sentence squeezed the heading onto two lines.
  let words = creations.reason_words(creations.NotAFolder)
  let #(head, after) = case string.split_once(missing, words) {
    Ok(split) -> split
    Error(Nil) -> #("", "")
  }
  assert string.contains(head, "New session in another folder")
  assert string.ends_with(
    head,
    "</div><p class=\"notice-refusal\" role=\"status\">",
  )
  assert after != ""

  let unopened = drawn(refuse(creations.NotOpened))
  assert string.contains(unopened, creations.reason_words(creations.NotOpened))
  assert !string.contains(unopened, "name=\"path\"")
}

// A remembered folder's refusal is drawn in the same section, since the folder
// has no group to put it beside.
pub fn a_refused_remembered_folder_is_worded_in_the_section_test() {
  let rows = [recent(7, "/home/o/gone")]
  let ask = fn(_, _, _, deliver) {
    deliver(creations.Declined(creations.NotAFolder))
  }
  let start =
    home.Start(
      ..creator(ask),
      folders: Some(
        home.Folders(recent: fn(deliver) { deliver(rows) }, forget: fn(_, _) {
          Nil
        }),
      ),
    )
  let #(model, _) = opened(start)
  let model = run(model, home.Choosing("/home/o/gone"))
  let model = run(model, home.Creating("/home/o/gone", "", creations.Private))
  let html = drawn(model)
  assert string.contains(html, creations.reason_words(creations.NotAFolder))
  assert string.contains(html, "<form")
}

// Forgetting asks the daemon with the identity the tree drew and the page then
// shows the list the daemon answered, so a removed folder disappears. A page
// that was handed no capability asks nothing.
pub fn a_forgotten_folder_disappears_test() {
  let asked = process.new_subject()
  let forgotten = process.new_subject()
  let rows = [recent(7, "/home/o/a"), recent(6, "/home/o/b")]
  let remaining = [recent(6, "/home/o/b")]
  let #(model, _) = opened(folder_keeper(rows, asked, forgotten, remaining))
  assert string.contains(drawn(model), "/home/o/a")

  let model = run(model, home.Forgetting(7))
  assert process.receive(forgotten, 0) == Ok(7)
  let html = drawn(model)
  assert !string.contains(html, "/home/o/a")
  assert string.contains(html, "/home/o/b")
  assert process.receive(forgotten, 0) == Error(Nil)
}

// The page keeps no more than the catalogue's bound from a read, and the paths
// it draws are text nodes: a hostile path is escaped and is in no attribute,
// including the key and the title.
pub fn remembered_paths_are_only_text_nodes_test() {
  let hostile = "/home/o/<img src=x onerror=alert(1)>"
  let asked = process.new_subject()
  let forgotten = process.new_subject()
  let rows = [recent(3, hostile)]
  let #(model, _) = opened(folder_keeper(rows, asked, forgotten, rows))
  let html = drawn(model)
  assert !string.contains(html, "<img")
  assert string.contains(html, "&lt;img")
  assert !string.contains(html, "title=\"/home/o")
  assert !string.contains(html, "value=\"/home/o")

  let many =
    list.repeat(Nil, home.recent_limit + 5)
    |> list.index_map(fn(_, id) {
      recent(id, "/home/o/f" <> string.inspect(id))
    })
  let model = run(model, home.FoldersRead(many))
  let drawn_rows =
    list.length(string.split(drawn(model), "Forget this folder")) - 1
  assert drawn_rows == home.recent_limit
}

// The typed form's fields decode totally: exactly one path, exactly one name, at
// most one box that reads `on`, and nothing else, so the workspace becomes a
// field in this form only and the forged field of another form is refused.
pub fn the_typed_folder_fields_decode_totally_test() {
  assert create.typed_fields([#("path", "~/app"), #("name", "")])
    == Ok(#("~/app", "", creations.Private))
  assert create.typed_fields([
      #("path", "/home/o/app"),
      #("name", "x"),
      #("shareable", "on"),
    ])
    == Ok(#("/home/o/app", "x", creations.Shareable))
  assert create.typed_fields([
      #("shareable", "on"),
      #("name", "x"),
      #("path", "~/app"),
    ])
    == Ok(#("~/app", "x", creations.Shareable))
  assert create.typed_fields([]) == Error(Nil)
  assert create.typed_fields([#("name", "x")]) == Error(Nil)
  assert create.typed_fields([#("path", "~/app")]) == Error(Nil)
  assert create.typed_fields([#("path", "~/a"), #("path", "~/b"), #("name", "")])
    == Error(Nil)
  assert create.typed_fields([#("path", "~/a"), #("name", "a"), #("name", "b")])
    == Error(Nil)
  assert create.typed_fields([
      #("path", "~/a"),
      #("name", ""),
      #("shareable", "yes"),
    ])
    == Error(Nil)
  assert create.typed_fields([
      #("path", "~/a"),
      #("name", ""),
      #("workspace", "/etc"),
    ])
    == Error(Nil)
  assert create.typed_fields([#("path", "~/a"), #("text", "x"), #("name", "")])
    == Error(Nil)

  // The workspace form still takes no path, so a forged `path` on it is refused.
  assert create.fields([#("name", "x"), #("path", "/etc")]) == Error(Nil)
}

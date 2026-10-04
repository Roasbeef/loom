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
import web_view/ending
import web_view/home
import web_view/page
import web_view/renames
import web_view/sessions.{type Entry, Blocked, Entry, Live, Saved}
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
  Entry(id:, name:, workspace:, created_at:, residency:, subtitle: None)
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
    sessions: read,
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, _) { Nil },
    rename: None,
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

fn settle(model: home.Model, dispatched: Subject(home.Msg)) -> home.Model {
  case process.receive(dispatched, 0) {
    Ok(next) -> run(model, next)
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

// The first read answers when the timer exists, the sessions are grouped by
// workspace with the newest workspace first, and the sessions of a workspace
// run newest first.
pub fn the_page_lists_the_sessions_grouped_by_workspace_test() {
  let #(model, _) = opened(start())
  assert home.status(model) == home.Connected
  assert list.map(home.groups(model), fn(group) { group.workspace })
    == ["/src/weft", "/src/notes", "/src/loom"]
  let assert [_, _, loom] = home.groups(model)
  assert list.map(loom.entries, fn(entry) { entry.id }) == ["B", "A"]
}

// A session a process runs and one that is on disk are told apart in words as
// well as a glyph, and an unnamed session is named by its identity.
pub fn resident_and_saved_are_marked_in_words_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert string.contains(html, "resident · created ")
  assert string.contains(html, "saved · ")
  assert string.contains(html, "Session D")
  assert string.contains(html, "vetting lint")

  // The centre is a list for each workspace, not a table: a heading with the
  // workspace's path and a count, and one item for each session.
  assert string.contains(html, "class=\"home-workspace\"")
  assert string.contains(html, ">/src/weft<")
  assert !string.contains(html, "<table")
  assert !string.contains(html, "<th")
  assert list.length(string.split(html, "class=\"home-row ")) == 5
}

// The workspace heading shortens the owner's home directory to `~` and keeps
// the whole path in its title, with the session count beside it.
pub fn the_workspace_heading_is_shortened_and_counted_test() {
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
    "<h3 class=\"home-workspace\" title=\"/Users/ada/src/loom\">~/src/loom"
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
    "resident · created <time datetime=\"1970-01-01T00:05Z\""
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
// daemon could not ask, it says only that the session is resident. A saved
// session has no activity, whatever a stale answer says.
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
  assert string.contains(html, "resident · working · created ")
  assert string.contains(html, "resident · needs you · created ")
  assert string.contains(html, "home-row working")
  assert string.contains(html, "home-row needs-you")
  assert !string.contains(html, "idle")
  assert !string.contains(html, "saved · idle")

  // Before the answer, a running row shows only that it is resident.
  let before =
    drawn(run(home.new(start()), home.Answered(home.Listed(listing()))))
  assert string.contains(before, "resident · created ")
  assert !string.contains(before, "working")
}

// Every answer replaces the last, so a session that went idle says so and one
// that stopped running leaves the words behind.
pub fn an_activity_answer_replaces_the_last_test() {
  let #(model, _) = opened(start())
  let model =
    run(model, home.Observed([#("B", sessions.Working), #("A", sessions.Idle)]))
  assert string.contains(drawn(model), "resident · idle · created ")
  let model = run(model, home.Observed([#("B", sessions.Idle)]))
  assert !string.contains(drawn(model), "working")
  assert list.length(string.split(drawn(model), "resident · idle")) == 2
}

// The daemon's own bound is the page's: no more running sessions than
// `activity_limit` are named in one read, the first ones in the order drawn,
// and a page with no running session asks nothing.
pub fn the_activity_read_is_bounded_and_skips_a_page_with_nothing_running_test() {
  let asked = process.new_subject()
  let ask = fn(ids, _) { process.send(asked, ids) }
  let many =
    list.repeat(Nil, home.activity_limit + 6)
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
  assert list.length(ids) == home.activity_limit
  assert list.first(ids) == Ok(string.inspect(home.activity_limit + 6))

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
  let ended = run(model, home.Answered(home.Closed(ending.AccessRevoked)))
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
    drawn(run(model, home.Answered(home.Closed(ending.AccessRevoked))))
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
  assert list.length(string.split(html, "<button")) == 5
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
  assert list.length(string.split(html, "<button")) == 9
  assert string.contains(html, "title=\"Resume this session\"")
  assert string.contains(html, "stuck")

  let #(observer, _) =
    opened(start_with(home.ObserverCeiling, fn() { home.Listed(with_blocked) }))
  assert list.length(handlers(home.view(observer))) == 4
}

// A resume press hands the session to the daemon's task and returns: the row
// reads "opening", no saved row has a press while it is out, and a second press
// asks nothing, even one that names another saved row.
pub fn a_resume_marks_its_row_and_a_second_press_asks_nothing_test() {
  let asked = process.new_subject()
  let #(model, _) =
    opened(home.Start(..start(), resume: fn(id, _) { process.send(asked, id) }))
  let model = run(model, home.Resuming("C"))
  assert process.receive(asked, 0) == Ok("C")
  let html = drawn(model)
  assert string.contains(html, "opening")
  assert string.contains(html, "It may take a moment.")

  // Only the two running rows keep a press, in each region.
  assert list.length(handlers(home.view(model))) == 4

  let model = run(model, home.Resuming("D"))
  let model = run(model, home.Resuming("C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert list.length(handlers(home.view(model))) == 4
}

// The task's answer arrives as a message from the task's own process: a ticket
// becomes the address the hidden element navigates to and clears the pending
// row, and a refusal is the reason's fixed words with the presses restored.
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
  assert !string.contains(html, "<span class=\"residency opening\"")
  assert list.length(handlers(home.view(model))) == 8

  let #(model, _) =
    opened(
      home.Start(..start(), resume: fn(_, deliver) {
        deliver(sessions.Declined(sessions.NotOpened))
      }),
    )
  let model = run(model, home.Resuming("C"))
  let html = drawn(model)
  assert string.contains(html, sessions.reason_words(sessions.NotOpened))
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
  let ended = run(operator, home.Answered(home.Closed(ending.AccessRevoked)))
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
  assert string.contains(html, "Opening that session.")
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
  let model = run(model, home.Answered(home.Closed(ending.AccessRevoked)))
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
  assert string.contains(html, ">operator<")
  assert string.contains(html, ">connected<")
  let #(observer, _) =
    opened(start_with(home.ObserverCeiling, fn() { home.Listed([]) }))
  assert string.contains(drawn(observer), ">read-only<")
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
  let model = run(model, home.Answered(home.Unread))
  assert home.status(model) == home.Connected
  assert list.length(home.groups(model)) == 3

  // A page that never read stays connecting.
  let fresh = run(home.new(start()), home.Answered(home.Unread))
  assert home.status(fresh) == home.Connecting
}

// A list replaces the last: a session that is gone is gone from the page.
pub fn a_new_list_replaces_the_old_one_test() {
  let #(model, _) = opened(start())
  let model =
    run(
      model,
      home.Answered(home.Listed([entry("A", "web ui", "/src/loom", 1, Live)])),
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
  let model = run(model, home.Answered(home.Closed(ending.AccessRevoked)))
  assert home.status(model) == home.Ended(ending.AccessRevoked)
  let html = drawn(model)
  assert string.contains(html, ">disconnected<")
  assert string.contains(html, "Your access was revoked or changed.")
  assert string.contains(html, "Run `loom ui` for a fresh link.")
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
  assert string.contains(shell, "<title>Loom · Home</title>")
  assert string.contains(shell, "<lustre-server-component>")
  assert string.contains(shell, page.asset_path(page.page_asset))
  assert string.contains(shell, page.asset_path(page.client_asset))
  assert string.contains(shell, "run `loom ui` for a fresh link")
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
    assert string.contains(ending.home_advice(reason), "`loom ui`")
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
    "<span class=\"home-subtitle\">Fix the flaky retry test</span> · resident",
  )
  assert string.contains(
    html,
    "<span class=\"home-subtitle\">Port the parser</span> · saved",
  )

  // A and D have no subtitle, so they read as before.
  assert string.contains(html, "resident · created ")
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

  // The row's own handler is the item's, first in the row; the button is the
  // second child, so no existing path moved.
  let added = list.filter(with, fn(key) { !list.contains(without, key) })
  assert list.length(added) == 4
  assert list.all(added, fn(key) {
    string.starts_with(key, home.table_path <> "\t")
    && string.ends_with(key, "\t1\nclick")
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
  assert string.contains(html, "Rename vetting lint")
  assert string.contains(html, "name=\"text\"")
  assert !string.contains(html, "value=\"vetting lint")
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
  assert string.contains(html, "Rename web ui")
  assert !string.contains(html, "Rename vetting lint")

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
  assert string.contains(drawn(model), "Rename vetting lint")
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

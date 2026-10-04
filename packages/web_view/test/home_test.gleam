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
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/ending
import web_view/home
import web_view/page
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
  Entry(id:, name:, workspace:, created_at:, residency:)
}

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
  assert string.contains(html, ">resident<")
  assert string.contains(html, ">saved<")
  assert string.contains(html, "Session D")
  assert string.contains(html, "vetting lint")

  // The table has a caption naming the workspace's whole path, and a header
  // for each column.
  assert string.contains(html, ">/src/weft</caption>")
  assert string.contains(html, "scope=\"col\">Name<")
  assert string.contains(html, "scope=\"col\">State<")
  assert string.contains(html, "scope=\"col\">Created<")
}

// The catalogue's creation time is drawn as UTC, from the integer alone.
pub fn the_creation_time_is_shown_in_utc_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert string.contains(html, "datetime=\"2026-09-21T14:13Z\"")
  assert string.contains(html, ">2026-09-21 14:13 UTC<")
  assert string.contains(html, ">1970-01-01 00:08 UTC<")
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
    "<p aria-current=\"page\" class=\"sidebar-home\">Home</p>",
  )
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
    assert string.contains(refusal, "Run `loom ui`")
    assert !string.contains(refusal, "--session")
    assert !string.contains(refusal, "<script")
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

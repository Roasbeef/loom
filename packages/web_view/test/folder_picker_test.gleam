//// The composer's folder picker (protocol-change/132): its model in
//// `web_view/composer` and its page in `view/new_session`, driven through the
//// home component.
////
//// What these tests pin: "Choose a folder…" opens the picker and asks for the
//// home; a press names an index into the listing the page holds, and an index it
//// did not draw changes nothing; an answer for a trail the page is no longer
//// waiting on is dropped; a refusal keeps the listing and says why; the home
//// cannot be chosen; a picked folder reaches the daemon as the typed `~/` path it
//// judges; a directory's name is drawn as text; and every handler of the picker
//// is beneath the region the owner's socket admits.

import core/agency_limits
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/composer
import web_view/creations
import web_view/folder_browse.{Child, Listing, Plain, Repository, Whole}
import web_view/home
import web_view/placements
import web_view/sessions.{Entry, Live}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

// A small tree below the home: `code` holds a repository and a plain folder, and
// `code/app` holds nothing. Every other trail is refused.
fn tree(trail: List(String)) -> folder_browse.Answer {
  case trail {
    [] ->
      Ok(Listing(
        trail: [],
        children: [Child("code", Plain), Child("<b>notes</b>", Plain)],
        cut: Whole,
      ))
    ["code"] ->
      Ok(Listing(
        trail: ["code"],
        children: [Child("app", Repository), Child("docs", Plain)],
        cut: Whole,
      ))
    ["code", "app"] ->
      Ok(Listing(trail: ["code", "app"], children: [], cut: Whole))
    _ -> Error(folder_browse.NotAFolder)
  }
}

fn offers(typing: composer.Typing) -> composer.Offers {
  composer.Offers(
    machine: "laptop",
    folders: ["/src/loom"],
    cards: placements.listed([], []),
    profiles: [],
    models: [],
    agent: composer.Here,
    here: "laptop",
    agents: [],
    typing:,
  )
}

fn step(
  state: composer.State,
  message: composer.Msg,
) -> #(composer.State, composer.Intent) {
  composer.update(state, message, offers(composer.MayType), [])
}

fn at(trail: List(String)) -> composer.State {
  let assert Ok(listing) = tree(trail) as "the fixture tree has this trail"
  composer.State(
    ..composer.new(),
    open: composer.Showing(composer.CodeChip),
    browser: composer.Browsing(listing:, refusal: None),
  )
}

// "Choose a folder…" opens the picker at the home and asks for it, and only a page
// that may type a path, which is where the daemon serving the page is the agent.
pub fn the_picker_opens_at_the_home_test() {
  let #(state, intent) = step(composer.new(), composer.OpenedBrowser)
  assert state.browser == composer.Reading(trail: [], behind: None)
  assert intent == composer.Browse(trail: [])

  let #(shut, none) =
    composer.update(
      composer.new(),
      composer.OpenedBrowser,
      offers(composer.MayNotType),
      [],
    )
  assert shut.browser == composer.Closed
  assert none == composer.Stay
}

// The answer for the trail asked settles the picker, and one for any other trail
// is dropped, so a slow answer never overwrites a newer press.
pub fn only_the_answer_awaited_settles_the_picker_test() {
  let #(waiting, _) = step(composer.new(), composer.OpenedBrowser)
  let assert Ok(home_listing) = tree([])

  let stale = composer.browsed(waiting, ["code"], tree(["code"]))
  assert stale == waiting

  let settled = composer.browsed(waiting, [], Ok(home_listing))
  assert settled.browser == composer.Browsing(home_listing, None)

  // Once settled, a late duplicate changes nothing.
  assert composer.browsed(settled, [], tree(["code"])) == settled
}

// A refusal keeps the listing the person was on and says why. A refusal of the
// first read leaves only the words.
pub fn a_refusal_keeps_the_listing_in_view_test() {
  let #(reading, intent) = step(at([]), composer.Descended(0))
  assert intent == composer.Browse(trail: ["code"])

  let refused =
    composer.browsed(reading, ["code"], Error(folder_browse.Unreadable))
  let assert composer.Browsing(listing:, refusal: Some(why)) = refused.browser
  assert listing.trail == []
  assert why == folder_browse.Unreadable

  let #(first, _) = step(composer.new(), composer.OpenedBrowser)
  let failed = composer.browsed(first, [], Error(folder_browse.NoHome))
  assert failed.browser == composer.Failed(folder_browse.NoHome)
}

// A press names an index into the listing the page holds. One it did not draw, a
// negative one, or a press while nothing is listed, reads nothing.
pub fn a_forged_index_reads_nothing_test() {
  let #(state, intent) = step(at([]), composer.Descended(1))
  assert intent == composer.Browse(trail: ["<b>notes</b>"])
  let assert composer.Reading(trail: ["<b>notes</b>"], behind: Some(_)) =
    state.browser

  list.each([2, 99, -1], fn(index) {
    let #(unchanged, nothing) = step(at([]), composer.Descended(index))
    assert unchanged == at([])
    assert nothing == composer.Stay
  })

  let #(closed, nothing) = step(composer.new(), composer.Descended(0))
  assert closed == composer.new()
  assert nothing == composer.Stay
}

// The way up and the breadcrumbs read an ancestor, and the directory on screen or
// one below it is no ancestor.
pub fn only_an_ancestor_is_read_on_the_way_up_test() {
  let #(_, up) = step(at(["code", "app"]), composer.Ascended(1))
  assert up == composer.Browse(trail: ["code"])

  let #(_, home_) = step(at(["code", "app"]), composer.Ascended(0))
  assert home_ == composer.Browse(trail: [])

  list.each([2, 3, -1], fn(depth) {
    let #(unchanged, nothing) =
      step(at(["code", "app"]), composer.Ascended(depth))
    assert unchanged == at(["code", "app"])
    assert nothing == composer.Stay
  })
}

// "Use this folder" chooses the directory on screen, closes the list, and reaches
// the daemon as the typed path it judges. The home itself is refused.
pub fn the_directory_on_screen_is_chosen_test() {
  let #(chosen, _) = step(at(["code", "app"]), composer.ChosePicked)
  assert chosen.target == Some(composer.Picked(["code", "app"]))
  assert chosen.open == composer.Shut
  assert chosen.browser == composer.Closed

  assert composer.place(composer.Picked(["code", "app"]), composer.Nothing)
    == Ok(creations.Typed("~/code/app"))
  assert composer.target_words(composer.Picked(["code", "app"])) == "~/code/app"

  let #(unchanged, _) = step(at([]), composer.ChosePicked)
  assert unchanged == at([])
}

// A picked folder is made only by "Use this folder": a message that carries one
// is refused, and a trail that is empty or climbs is not an offered target.
pub fn a_picked_target_cannot_be_forged_test() {
  let #(state, _) =
    step(composer.new(), composer.ChoseTarget(composer.Picked(["code"])))
  assert state.target == None

  let may = offers(composer.MayType)
  assert composer.offered(may, composer.Picked(["code"]))
  assert !composer.offered(may, composer.Picked([]))
  assert !composer.offered(may, composer.Picked(["code", ".."]))
  assert !composer.offered(
    offers(composer.MayNotType),
    composer.Picked(["code"]),
  )
}

// --- the page ----------------------------------------------------------------

fn owner(asked: Subject(creations.Place), browsed: Subject(List(String))) {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) {
      deliver(
        home.Listed([
          Entry(
            id: "B",
            name: "vetting lint",
            workspace: "/src/loom",
            created_at: 300_000,
            residency: Live,
            subtitle: None,
            role: None,
            project: None,
            executor: None,
            standing: sessions.Ordinary,
          ),
        ]),
      )
    },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 7_400_000 },
    activity: fn(_, _) { Nil },
    rename: None,
    manage: None,
    thread_send: None,
    attention: None,
    create: Some(fn(place, _, _, _, _: agency_limits.AgencyLimits, _, _) {
      process.send(asked, place)
    }),
    folders: Some(
      home.Folders(
        recent: fn(_) { Nil },
        forget: fn(_, _) { Nil },
        browse: fn(trail, deliver) {
          process.send(browsed, trail)
          deliver(tree(trail))
        },
      ),
    ),
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
    passkeys: None,
    visiting: None,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "laptop",
    placements: fn(deliver) {
      deliver(placements.Reported(placements.Placements([], [])))
    },
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

fn opened(start: home.Start) -> home.Model {
  run(home.new(start), home.TimerReady(process.new_subject()))
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

fn compose(model: home.Model, message: composer.Msg) -> home.Model {
  run(model, home.Composed(message))
}

fn pressing(model: home.Model, messages: List(composer.Msg)) -> home.Model {
  list.fold(messages, model, compose)
}

// The Code list offers "Choose a folder…", which opens the picker: a breadcrumb at
// the home, the recent folders first, then the home's folders, and no "Use this
// folder", since a session may not start in the home itself.
pub fn the_picker_opens_in_the_code_list_test() {
  let asked = process.new_subject()
  let browsed = process.new_subject()
  let model = opened(owner(asked, browsed))
  let listed = compose(model, composer.Toggled(composer.CodeChip))
  assert string.contains(drawn(listed), "Choose a folder…")
  assert string.contains(drawn(listed), "Browse your folders")

  let html = drawn(compose(listed, composer.OpenedBrowser))
  assert process.receive(browsed, 0) == Ok([])
  assert string.contains(html, "aria-label=\"Folder path\"")
  assert string.contains(html, "Recent")
  assert string.contains(html, "/src/loom")
  assert string.contains(html, "Your home")
  assert string.contains(html, ">code<")
  assert !string.contains(html, "Use this folder")
  assert string.contains(html, "Open a folder to use it.")
  assert string.contains(html, "Type a path instead")
  assert string.contains(html, "Back to the list")
}

// Pressing a row descends: the daemon is asked for the child's trail, the
// breadcrumb grows, a repository is marked, the way up appears, and "Use this
// folder" chooses it. Starting then asks the daemon for the typed `~/` place.
pub fn descending_and_choosing_starts_in_that_folder_test() {
  let asked = process.new_subject()
  let browsed = process.new_subject()
  let model =
    opened(owner(asked, browsed))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.OpenedBrowser,
      composer.Descended(0),
    ])

  assert process.receive(browsed, 0) == Ok([])
  assert process.receive(browsed, 0) == Ok(["code"])
  let html = drawn(model)
  assert string.contains(html, "Git repository")
  assert string.contains(html, "Up one folder")
  assert string.contains(html, "Use this folder")
  assert string.contains(html, "aria-current=\"page\"")

  let model = pressing(model, [composer.Descended(0), composer.ChosePicked])
  let html = drawn(model)
  assert string.contains(html, "~/code/app")
  assert !string.contains(html, "aria-label=\"Folder path\"")

  let _ = run(model, home.Composed(composer.Started("go", composer.Nothing)))
  assert process.receive(asked, 0) == Ok(creations.Typed("~/code/app"))
}

// A refused read says why, in words that carry no path, and the listing stays.
pub fn a_refused_read_is_worded_over_the_listing_test() {
  let asked = process.new_subject()
  let browsed = process.new_subject()
  let model =
    opened(owner(asked, browsed))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.OpenedBrowser,
      composer.Descended(0),
      composer.Descended(1),
    ])
  let html = drawn(model)
  assert string.contains(
    html,
    folder_browse.refusal_words(folder_browse.NotAFolder),
  )
  assert string.contains(html, "role=\"alert\"")
  assert string.contains(html, "Git repository")
}

// A directory's name is text: markup in one is escaped, never a tag.
pub fn a_directory_name_is_drawn_as_text_test() {
  let model =
    opened(owner(process.new_subject(), process.new_subject()))
    |> pressing([composer.Toggled(composer.CodeChip), composer.OpenedBrowser])
  let html = drawn(model)
  assert !string.contains(html, "<b>notes</b>")
  assert string.contains(html, "&lt;b&gt;notes&lt;/b&gt;")
}

// Every handler of the open picker is beneath the region the owner's socket
// admits, and the picker draws no input, so the search's handler is gone.
pub fn every_picker_handler_is_beneath_the_table_region_test() {
  let model =
    opened(owner(process.new_subject(), process.new_subject()))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.OpenedBrowser,
      composer.Descended(0),
    ])
  let keys = handlers(home.view(model))

  assert keys != []
  assert list.all(keys, fn(key) {
    string.starts_with(key, home.table_path <> "\t")
    || string.starts_with(key, home.sidebar_path <> "\t")
    || string.starts_with(key, home.signins_path <> "\t")
  })
  assert list.count(keys, string.ends_with(_, "\ninput")) == 0
}

// A page whose daemon handed it no listing capability draws the row but closes
// the picker at once, so it never waits for an answer that cannot come.
pub fn a_page_without_listing_closes_the_picker_test() {
  let start =
    home.Start(
      ..owner(process.new_subject(), process.new_subject()),
      folders: None,
    )
  let model =
    opened(start)
    |> pressing([composer.Toggled(composer.CodeChip), composer.OpenedBrowser])
  assert !string.contains(drawn(model), "aria-label=\"Folder path\"")
}

// A page that may not create has no composer and ignores the messages.
pub fn a_page_that_may_not_create_has_no_picker_test() {
  let start =
    home.Start(
      ..owner(process.new_subject(), process.new_subject()),
      create: None,
    )
  let model = opened(start) |> pressing([composer.OpenedBrowser])
  assert !string.contains(drawn(model), "Folder path")
  assert !string.contains(drawn(model), "Choose a folder")
}

//// The composer's folder search (protocol-change/132, the addendum on searching):
//// its model in `web_view/composer` and its list in `view/new_session`, driven
//// through the home component.
////
//// What these tests pin: a fragment of two characters or more owes the daemon one
//// search, and a shorter one or a page that may not search owes none; an answer
//// for a fragment the person has since changed is dropped; a longer fragment
//// narrows the hits on show at once; the rows are the remembered folders, then the
//// found ones, then the projects, each matched by a fragment anywhere in its path,
//// with a found folder that a remembered one already shows left out; Enter chooses
//// the first row; a press on a found folder names an index the page holds, and one
//// it did not draw changes nothing; a project is offered only when the daemon
//// listed it; and a name or path is drawn as text and never as an attribute.

import core/agency_limits
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/composer
import web_view/creations
import web_view/folder_browse.{Covered, Found, Hit, Plain, Repository, Stopped}
import web_view/home
import web_view/placements
import web_view/sessions.{Entry, Live}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn offers(typing: composer.Typing) -> composer.Offers {
  composer.Offers(
    machine: "laptop",
    folders: ["/Users/o/work/loom", "/Users/o/work/weft"],
    cards: placements.listed([], []),
    profiles: [],
    models: [],
    agent: composer.Here,
    here: "laptop",
    agents: [],
    typing:,
    projects: ["/Users/o/code/atlas"],
  )
}

fn step(
  state: composer.State,
  message: composer.Msg,
) -> #(composer.State, composer.Intent) {
  composer.update(state, message, offers(composer.MayType), [])
}

fn listed() -> composer.State {
  composer.State(..composer.new(), open: composer.Showing(composer.CodeChip))
}

fn hit(trail: List(String)) -> folder_browse.Hit {
  Hit(trail:, marker: Plain)
}

fn names(choices: List(composer.Choice)) -> List(String) {
  list.map(choices, fn(each) { each.name })
}

// --- the model ---------------------------------------------------------------

// A fragment of two characters is asked of the daemon once, in the lowercase and
// trimmed form the daemon judges again. One character, nothing, or a page that may
// not type a path asks for nothing.
pub fn a_fragment_owes_the_daemon_one_search_test() {
  let #(asking, intent) = step(listed(), composer.Searched("  LoOm "))
  assert intent == composer.Find("loom")
  assert asking.seek == composer.Seeking("loom", [])

  // The same fragment again, as a keystroke that changed nothing might send, is
  // not asked twice.
  let #(again, quiet) = step(asking, composer.Searched("loom"))
  assert again.seek == asking.seek
  assert quiet == composer.Stay

  let #(short, none) = step(asking, composer.Searched("l"))
  assert short.seek == composer.Unsought
  assert none == composer.Stay

  let #(shut, never) =
    composer.update(
      listed(),
      composer.Searched("loom"),
      offers(composer.MayNotType),
      [],
    )
  assert shut.seek == composer.Unsought
  assert never == composer.Stay
}

// The answer settles the search only while the page waits for that fragment, and
// the hits of the answer before stay on show, narrowed to what is now typed.
pub fn only_the_answer_awaited_settles_the_search_test() {
  let #(asking, _) = step(listed(), composer.Searched("lo"))
  let found = Found([hit(["a", "loom"]), hit(["b", "lodge"])], Covered)

  assert composer.found(asking, "loom", Ok(found)) == asking

  let settled = composer.found(asking, "lo", Ok(found))
  assert settled.seek == composer.Sought("lo", found)

  // A longer fragment is asked, and until it is answered the hits that no longer
  // match are not drawn.
  let #(longer, intent) = step(settled, composer.Searched("loo"))
  assert intent == composer.Find("loo")
  let drawn = composer.choices(longer, offers(composer.MayType)).found
  assert names(drawn) == ["loom"]

  // A late answer for the old fragment changes nothing.
  assert composer.found(longer, "lo", Ok(found)) == longer
}

// A refusal is kept with its words and draws no folder.
pub fn a_refused_search_keeps_its_words_test() {
  let #(asking, _) = step(listed(), composer.Searched("loom"))
  let refused = composer.found(asking, "loom", Error(folder_browse.Unreadable))
  assert refused.seek == composer.Unsearchable("loom", folder_browse.Unreadable)
  assert composer.choices(refused, offers(composer.MayType)).found == []
}

// The rows: the remembered folders the text matches anywhere in the path, the
// found ones that no remembered folder shows, and the projects.
pub fn the_rows_are_remembered_then_found_then_projects_test() {
  let state = composer.State(..listed(), search: "o")
  let all = composer.choices(state, offers(composer.MayType))
  assert names(all.recent) == ["loom", "weft"]
  assert names(all.projects) == ["atlas"]

  // `work` is in both remembered paths, so both stay; `weft` matches only by name.
  let by_parent =
    composer.choices(
      composer.State(..listed(), search: "WORK"),
      offers(composer.MayType),
    )
  assert names(by_parent.recent) == ["loom", "weft"]
  assert by_parent.projects == []

  // A found folder that a remembered one already shows is left out, and the
  // others keep the index a press names.
  let #(asking, _) = step(listed(), composer.Searched("loom"))
  let found =
    Found(
      [
        hit(["work", "loom"]),
        hit(["code", "loom-picker"]),
        hit(["x", "loomy"]),
      ],
      Covered,
    )
  let settled = composer.found(asking, "loom", Ok(found))
  let rows = composer.choices(settled, offers(composer.MayType))
  assert names(rows.recent) == ["loom"]
  assert names(rows.found) == ["loom-picker", "loomy"]
  assert list.map(rows.found, fn(each) { each.found }) == [Some(1), Some(2)]
  assert list.map(rows.found, fn(each) { each.parent }) == ["~/code", "~/x"]
}

// Enter chooses the first row in the order the list draws, and changes nothing
// when there is none.
pub fn enter_chooses_the_first_row_test() {
  let #(asking, _) = step(listed(), composer.Searched("atlas"))
  let #(project, _) = step(asking, composer.Entered)
  assert project.target == Some(composer.Project("/Users/o/code/atlas"))
  assert project.open == composer.Shut
  assert project.search == ""
  assert project.seek == composer.Unsought

  let #(asking, _) = step(listed(), composer.Searched("loom"))
  let settled =
    composer.found(asking, "loom", Ok(Found([hit(["x", "loomy"])], Covered)))
  let #(chosen, _) = step(settled, composer.Entered)
  assert chosen.target == Some(composer.Folder("/Users/o/work/loom"))

  let #(only_found, _) =
    composer.update(
      settled,
      composer.Entered,
      composer.Offers(..offers(composer.MayType), folders: []),
      [],
    )
  assert only_found.target == Some(composer.Picked(["x", "loomy"]))

  let #(nothing, _) =
    step(composer.State(..listed(), search: "zzzz"), composer.Entered)
  assert nothing.target == None
  assert nothing.open == composer.Showing(composer.CodeChip)
}

// A found folder is chosen by an index into the hits the page holds. An index it
// did not draw, or a message on a page that may not type a path, chooses nothing.
pub fn a_found_folder_is_chosen_by_index_test() {
  let #(asking, _) = step(listed(), composer.Searched("loom"))
  let settled =
    composer.found(
      asking,
      "loom",
      Ok(Found([hit(["x", "loomy"]), hit(["y", "loomer"])], Covered)),
    )

  let #(chosen, _) = step(settled, composer.ChoseFound(1))
  assert chosen.target == Some(composer.Picked(["y", "loomer"]))
  assert composer.place(composer.Picked(["y", "loomer"]), composer.Nothing)
    == Ok(creations.Typed("~/y/loomer"))

  list.each([-1, 2, 99], fn(index) {
    let #(same, _) = step(settled, composer.ChoseFound(index))
    assert same == settled
  })

  let #(blocked, _) =
    composer.update(
      settled,
      composer.ChoseFound(0),
      offers(composer.MayNotType),
      [],
    )
  assert blocked == settled
}

// A project is offered only when the daemon listed it, is chosen like a folder, and
// is judged as a typed path when the session is created.
pub fn a_project_is_offered_only_when_listed_test() {
  let target = composer.Project("/Users/o/code/atlas")
  assert composer.offered(offers(composer.MayType), target)
  assert !composer.offered(
    composer.Offers(..offers(composer.MayType), projects: []),
    target,
  )
  assert composer.place(target, composer.Nothing)
    == Ok(creations.Typed("/Users/o/code/atlas"))
  assert composer.target_words(target) == "atlas"

  let #(chosen, _) = step(listed(), composer.ChoseTarget(target))
  assert chosen.target == Some(target)
  let #(refused, _) =
    composer.update(
      listed(),
      composer.ChoseTarget(composer.Project("/Users/o/elsewhere")),
      offers(composer.MayType),
      [],
    )
  assert refused.target == None
}

// A folder is told by its own name and where it lives, shortened.
pub fn a_folder_has_a_name_and_a_parent_test() {
  assert composer.name_of("/Users/o/work/loom") == "loom"
  assert composer.name_of("~/loom") == "loom"
  assert composer.name_of("/") == "/"
  assert composer.parent_of("/Users/o/work/loom") == "…/o/work"
  assert composer.parent_of("~/code/loom") == "~/code"
  assert composer.parent_of("~/loom") == "~"
  assert composer.parent_of("/loom") == "/"
}

// The fragment is judged here as the daemon judges it, and a hit is matched by its
// name unless the fragment holds a slash.
pub fn the_fragment_and_the_match_follow_one_rule_test() {
  assert folder_browse.needle("  Loom ") == Ok("loom")
  assert folder_browse.needle("l") == Error(Nil)
  assert folder_browse.needle("a\nb") == Error(Nil)
  assert folder_browse.matches("oom", ["code", "Loom"])
  assert !folder_browse.matches("code", ["code", "app"])
  assert folder_browse.matches("code/app", ["code", "app"])
  assert folder_browse.hit_trail([hit(["a"])], 0) == Ok(["a"])
  assert folder_browse.hit_trail([hit(["a"])], 1) == Error(Nil)
  assert folder_browse.hit_trail([hit(["a"])], -1) == Error(Nil)
}

// --- the page ----------------------------------------------------------------

fn owner(
  searched: Subject(String),
  answer: folder_browse.FindAnswer,
) -> home.Start {
  silent(searched, Some(answer))
}

// The owner's page whose daemon answers a search with `answer`, or never, so the
// search stays out.
fn silent(
  searched: Subject(String),
  answer: option.Option(folder_browse.FindAnswer),
) -> home.Start {
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
    create: Some(fn(_, _, _, _, _: agency_limits.AgencyLimits, _, _) { Nil }),
    folders: Some(
      home.Folders(
        recent: fn(_) { Nil },
        forget: fn(_, _) { Nil },
        browse: fn(_, _) { Nil },
        find: fn(needle, deliver) {
          process.send(searched, needle)
          case answer {
            Some(answer) -> deliver(answer)
            None -> Nil
          }
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

// Typing in the open list asks the daemon once, and the answer is drawn under a
// "Folders" heading with each folder's name and its parent as text, beside a
// remembered folder, which keeps the "Recent" heading.
pub fn typing_asks_the_daemon_and_draws_the_answer_test() {
  let searched = process.new_subject()
  let found =
    Found(
      [
        Hit(["code", "loom-picker"], Repository),
        Hit(["<b>notes</b>", "loom"], Plain),
      ],
      Covered,
    )
  let model =
    opened(owner(searched, Ok(found)))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  let html = drawn(model)

  assert process.receive(searched, 0) == Ok("loom")
  assert process.receive(searched, 0) == Error(Nil)
  assert string.contains(html, "<loom-picklist>")
  assert string.contains(html, "class=\"search\"")
  assert string.contains(html, "Recent")
  assert string.contains(html, ">loom<")
  assert string.contains(html, ">/src<")
  assert string.contains(html, "Folders")
  assert string.contains(html, ">loom-picker<")
  assert string.contains(html, ">~/code<")
  assert string.contains(html, "&lt;b&gt;notes&lt;/b&gt;")
  assert !string.contains(html, "<b>notes</b>")
  assert string.contains(html, "Open folder…")
  assert !string.contains(html, "Searching…")
}

// While the answer is out the list says so, and a search that stopped says that
// too.
pub fn the_list_says_when_it_searches_and_when_it_stopped_test() {
  let waiting =
    opened(silent(process.new_subject(), None))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  assert string.contains(drawn(waiting), "Searching…")

  let stopped =
    opened(owner(
      process.new_subject(),
      Ok(Found([hit(["a", "loomy"])], Stopped)),
    ))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  assert string.contains(drawn(stopped), "Showing the first matches.")

  let empty =
    opened(owner(process.new_subject(), Ok(Found([], Covered))))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("zzzz"),
    ])
  assert string.contains(drawn(empty), "Nothing matches that search.")
}

// A page whose daemon gave it no folder capability asks for nothing and does not
// say it is searching.
pub fn a_page_without_the_capability_never_searches_test() {
  let start =
    home.Start(
      ..owner(process.new_subject(), Ok(Found([], Covered))),
      folders: None,
    )
  let model =
    opened(start)
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  assert !string.contains(drawn(model), "Searching…")
}

// Pressing a found folder chooses it, and the creation is asked for the typed
// path the daemon judges.
pub fn a_found_folder_reaches_the_daemon_as_a_typed_path_test() {
  let model =
    opened(owner(
      process.new_subject(),
      Ok(Found([hit(["code", "loom-picker"])], Covered)),
    ))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("picker"),
      composer.ChoseFound(0),
    ])
  let html = drawn(model)
  assert string.contains(html, "place-chip-value\">loom-picker")
  assert string.contains(html, "~/code/loom-picker")
}

// Every handler of the open list is beneath the region the owner's socket admits:
// one input, the search's, and the submits of the search and of the form.
pub fn every_search_handler_is_beneath_the_table_region_test() {
  let model =
    opened(owner(
      process.new_subject(),
      Ok(Found([hit(["a", "loomy"])], Covered)),
    ))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  let keys = handlers(home.view(model))

  assert list.all(keys, fn(key) {
    string.starts_with(key, home.table_path <> "\t")
    || string.starts_with(key, home.sidebar_path <> "\t")
    || string.starts_with(key, home.signins_path <> "\t")
  })
  assert list.count(keys, string.ends_with(_, "\ninput")) == 1
  assert list.count(keys, string.ends_with(_, "\nsubmit")) == 2
}

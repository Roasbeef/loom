//// The composer's folder search (protocol-change/132, the addendum on searching):
//// its model in `web_view/composer` and its list in `view/new_session`, driven
//// through the home component.
////
//// What these tests pin: the daemon is asked for one index when the Code list
//// opens, and never for a keystroke, and never twice while one is out; an index is
//// kept for its lifetime and asked for again after it, after a refusal and not
//// before; the ranking puts an exact name before a prefix before any other match,
//// the shallower first; the rows are the remembered folders, then the found ones,
//// then the projects; a found folder is left out only when a remembered folder
//// drawn above it is the same directory by whole path; Enter chooses the first
//// row; a press on a found folder names an index the page holds, and one it did
//// not draw changes nothing; a project is offered only when the daemon listed it;
//// and a name or path is drawn as text and never as an attribute.

import core/agency_limits
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/composer
import web_view/creations
import web_view/folder_browse.{Covered, Entry, Index, Stopped}
import web_view/home
import web_view/placements
import web_view/sessions.{Entry as Session, Live}
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
    now: 1000,
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

fn entry(trail: List(String)) -> folder_browse.Entry {
  let assert Ok(name) = list.last(trail) as "a trail has a name"
  Entry(trail:, lower: string.lowercase(name))
}

fn index(trails: List(List(String))) -> folder_browse.Index {
  Index(home: "/Users/o", entries: list.map(trails, entry), reach: Covered)
}

// A state whose list is open and whose index is held, with the text typed.
fn typed(trails: List(List(String)), text: String) -> composer.State {
  composer.State(
    ..listed(),
    search: text,
    seek: composer.Indexed(index(trails), 1000),
  )
}

fn names(choices: List(composer.Choice)) -> List(String) {
  list.map(choices, fn(each) { each.name })
}

// --- the model ---------------------------------------------------------------

// An open list owes one index, and a build that is out is not asked for again,
// whatever is typed meanwhile. A list that is shut, or a page that may not type a
// path, owes none.
pub fn an_open_list_owes_one_index_test() {
  let #(asking, seeds) = composer.indexing(listed(), offers(composer.MayType))
  assert asking.seek == composer.Indexing(None)
  assert seeds == Some(["/Users/o/work/loom", "/Users/o/work/weft"])

  // Typing while the build is out asks for nothing and costs no message.
  let #(typing, intent) = step(asking, composer.Searched("loom"))
  assert intent == composer.Stay
  let #(again, none) = composer.indexing(typing, offers(composer.MayType))
  assert again == typing
  assert none == None

  let #(shut, never) =
    composer.indexing(composer.new(), offers(composer.MayType))
  assert shut.seek == composer.Unindexed
  assert never == None
  let #(blocked, nothing) =
    composer.indexing(listed(), offers(composer.MayNotType))
  assert blocked.seek == composer.Unindexed
  assert nothing == None
}

// The answer settles the build only while one is out, and an index lives for its
// lifetime and is asked for again after it with the old one kept on show.
pub fn an_index_lives_for_its_lifetime_test() {
  let #(asking, _) = composer.indexing(listed(), offers(composer.MayType))
  let built = index([["loom"]])

  assert composer.indexed(listed(), Ok(built), 5) == listed()

  let held = composer.indexed(asking, Ok(built), 5)
  assert held.seek == composer.Indexed(built, 5)

  let young = composer.Offers(..offers(composer.MayType), now: 5 + 299_999)
  assert composer.indexing(held, young).1 == None
  let old = composer.Offers(..offers(composer.MayType), now: 5 + 300_000)
  let #(renewing, seeds) = composer.indexing(held, old)
  assert renewing.seek == composer.Indexing(Some(built))
  assert seeds != None
}

// A refusal is retried when the list next opens and not on a keystroke, whether it
// was the first build or a refresh of an index already held, and the held index
// stays in use meanwhile.
pub fn a_refusal_is_retried_at_the_next_open_not_the_next_keystroke_test() {
  let #(asking, _) = composer.indexing(listed(), offers(composer.MayType))
  let refused = composer.indexed(asking, Error(folder_browse.Unreadable), 5)
  assert refused.seek == composer.Unindexable(folder_browse.Unreadable, None)

  // A keystroke asks for nothing.
  let #(typing, _) = step(refused, composer.Searched("loom"))
  assert composer.indexing(typing, offers(composer.MayType)).1 == None

  // Closing and opening the list asks again.
  let #(shut, _) = step(typing, composer.Toggled(composer.CodeChip))
  let #(reopened, _) = step(shut, composer.Toggled(composer.CodeChip))
  assert reopened.seek == composer.Unindexed
  let #(retry, again) = composer.indexing(reopened, offers(composer.MayType))
  assert retry.seek == composer.Indexing(None)
  assert again != None

  // A refused refresh keeps the old index drawn, asks for nothing on a keystroke
  // and refreshes at the next open.
  let built = index([["loom"]])
  let stale =
    composer.State(..listed(), seek: composer.Indexed(built, 0), search: "loom")
  let old = composer.Offers(..offers(composer.MayType), now: 300_000)
  let #(renewing, _) = composer.indexing(stale, old)
  let kept =
    composer.indexed(renewing, Error(folder_browse.Unreadable), 300_000)
  assert kept.seek
    == composer.Unindexable(folder_browse.Unreadable, Some(built))
  assert list.length(composer.choices(kept, old).found) == 1
  let #(typed, _) = step(kept, composer.Searched("loomy"))
  assert composer.indexing(typed, old).1 == None
  let #(closed, _) = step(typed, composer.Toggled(composer.CodeChip))
  let #(open_again, _) = step(closed, composer.Toggled(composer.CodeChip))
  assert composer.indexing(open_again, old).1 != None
}

// Coming back from the folder picker the search field is empty, so the list is not
// filtered by text the person cannot see.
pub fn returning_from_the_picker_clears_the_search_test() {
  let #(browsing, _) =
    step(composer.State(..listed(), search: "loom"), composer.OpenedBrowser)
  assert browsing.search == ""
}

// The ranking: an exact name, then a name that starts with the fragment, then one
// that holds it, the shallower first and then the path in order, at most twenty.
pub fn the_ranking_orders_exact_then_prefix_then_contains_test() {
  let entries =
    list.map(
      [
        ["a", "b", "oldloom"],
        ["loom-picker"],
        ["x", "Loom"],
        ["loom"],
        ["code", "loomy"],
        ["y", "Loom"],
      ],
      entry,
    )

  assert folder_browse.rank(entries, "loom")
    == [
      ["loom"],
      ["x", "Loom"],
      ["y", "Loom"],
      ["loom-picker"],
      ["code", "loomy"],
      ["a", "b", "oldloom"],
    ]

  // Past twenty, the best twenty are kept, not the first twenty met.
  let many =
    list.append(
      list.map(string.to_graphemes("abcdefghijklmnopqrstuvwxyzABCD"), fn(each) {
        entry(["d", "loom" <> each])
      }),
      [entry(["deep", "er", "loom"])],
    )
  let top = folder_browse.rank(many, "loom")
  assert list.length(top) == folder_browse.find_limit
  assert list.first(top) == Ok(["deep", "er", "loom"])
}

// The rows: the remembered folders the text matches anywhere in the path, the found
// ones, and the projects; a found folder is left out only when a remembered folder
// drawn above it is the same directory by whole path.
pub fn the_rows_are_remembered_then_found_then_projects_test() {
  let all = composer.choices(typed([], "o"), offers(composer.MayType))
  assert names(all.recent) == ["loom", "weft"]
  assert names(all.projects) == ["atlas"]

  let by_parent = composer.choices(typed([], "WORK"), offers(composer.MayType))
  assert names(by_parent.recent) == ["loom", "weft"]
  assert by_parent.projects == []

  // `~/work/loom` is drawn as a remembered folder, so its found copy is left out.
  // `~/loom` has the same name and the same end of a path but is another folder,
  // and is kept, with the index a press names.
  let rows =
    composer.choices(
      typed([["work", "loom"], ["loom"], ["code", "loom-picker"]], "loom"),
      offers(composer.MayType),
    )
  assert names(rows.recent) == ["loom"]
  assert names(rows.found) == ["loom", "loom-picker"]
  assert list.map(rows.found, fn(each) { each.found }) == [Some(0), Some(2)]
  assert list.map(rows.found, fn(each) { each.parent }) == ["~", "~/code"]

  // A remembered folder that is not drawn, because the text does not match it,
  // hides nothing.
  let shown =
    composer.choices(
      typed([["work", "loom"]], "oom"),
      composer.Offers(..offers(composer.MayType), folders: [
        "/Users/o/archive/old",
      ]),
    )
  assert names(shown.found) == ["loom"]
}

// Enter chooses the first row in the order the list draws, and nothing when there
// is none.
pub fn enter_chooses_the_first_row_test() {
  let #(project, _) = step(typed([], "atlas"), composer.Entered)
  assert project.target == Some(composer.Project("/Users/o/code/atlas"))
  assert project.open == composer.Shut
  assert project.search == ""

  let #(chosen, _) = step(typed([["x", "loomy"]], "loom"), composer.Entered)
  assert chosen.target == Some(composer.Folder("/Users/o/work/loom"))

  let #(only_found, _) =
    composer.update(
      typed([["x", "loomy"]], "loom"),
      composer.Entered,
      composer.Offers(..offers(composer.MayType), folders: []),
      [],
    )
  assert only_found.target == Some(composer.Picked(["x", "loomy"]))

  let #(nothing, _) = step(typed([], "zzzz"), composer.Entered)
  assert nothing.target == None
  assert nothing.open == composer.Showing(composer.CodeChip)
}

// A found folder is chosen by an index into the ranking the page holds. An index
// it did not draw, or a message on a page that may not type a path, chooses
// nothing, and the index survives the list closing.
pub fn a_found_folder_is_chosen_by_index_test() {
  let state = typed([["x", "loomy"], ["y", "loomer"]], "loom")

  let #(chosen, _) = step(state, composer.ChoseFound(1))
  assert chosen.target == Some(composer.Picked(["y", "loomer"]))
  assert chosen.seek == state.seek
  assert composer.place(composer.Picked(["y", "loomer"]), composer.Nothing)
    == Ok(creations.Typed("~/y/loomer"))

  list.each([-1, 2, 99], fn(index) {
    let #(same, _) = step(state, composer.ChoseFound(index))
    assert same == state
  })

  let #(blocked, _) =
    composer.update(
      state,
      composer.ChoseFound(0),
      offers(composer.MayNotType),
      [],
    )
  assert blocked == state
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

// The fragment is judged once for the page and its `~/` is the home.
pub fn the_fragment_follows_one_rule_test() {
  assert folder_browse.needle("  Loom ") == Ok("loom")
  assert folder_browse.needle("~/code/app") == Ok("code/app")
  assert folder_browse.needle("~/") == Error(Nil)
  assert folder_browse.needle("l") == Error(Nil)
  assert folder_browse.needle("a\nb") == Error(Nil)
  assert folder_browse.hit_trail([["a"]], 0) == Ok(["a"])
  assert folder_browse.hit_trail([["a"]], 1) == Error(Nil)
  assert folder_browse.hit_trail([["a"]], -1) == Error(Nil)
}

// --- the page ----------------------------------------------------------------

fn owner(
  asked: Subject(List(String)),
  answer: folder_browse.IndexAnswer,
) -> home.Start {
  silent(asked, Some(answer))
}

// The owner's page whose daemon answers an index request with `answer`, or never,
// so the build stays out.
fn silent(
  asked: Subject(List(String)),
  answer: Option(folder_browse.IndexAnswer),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) {
      deliver(
        home.Listed([
          Session(
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
    create: Some(fn(_, _, _, _, _: agency_limits.AgencyLimits, _, _, _) { Nil }),
    folders: Some(
      home.Folders(
        recent: fn(_) { Nil },
        forget: fn(_, _) { Nil },
        browse: fn(_, _) { Nil },
        index: fn(seeds, deliver) {
          process.send(asked, seeds)
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

// Opening the list asks the daemon once for the index, with the remembered folders
// as seeds, and typing asks for nothing: the answer is ranked in memory and drawn
// under a "Folders" heading with each folder's name and its parent as text, beside
// a remembered folder, which keeps the "Recent" heading.
pub fn opening_asks_for_one_index_and_typing_asks_for_none_test() {
  let asked = process.new_subject()
  let built =
    Index(
      home: "/Users/o",
      entries: [
        Entry(["code", "loom-picker"], "loom-picker"),
        Entry(["<b>notes</b>", "loom"], "loom"),
      ],
      reach: Covered,
    )
  let model =
    opened(owner(asked, Ok(built)))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("lo"),
      composer.Searched("loom"),
    ])
  let html = drawn(model)

  assert process.receive(asked, 0) == Ok(["/src/loom"])
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(html, "<loom-picklist>")
  assert string.contains(html, "class=\"search\"")
  assert string.contains(html, "Recent")
  assert string.contains(html, "Folders")
  assert string.contains(html, ">loom-picker<")
  assert string.contains(html, ">~/code<")
  assert string.contains(html, "&lt;b&gt;notes&lt;/b&gt;")
  assert !string.contains(html, "<b>notes</b>")
  assert string.contains(html, "Open folder…")
  assert !string.contains(html, "Indexing")

  // Closing and opening again inside the index's lifetime asks for no second one.
  let again =
    pressing(model, [
      composer.Toggled(composer.CodeChip),
      composer.Toggled(composer.CodeChip),
    ])
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(again), "Open folder…")
}

// While the build is out the list says so, a build that stopped says that, and a
// refusal says why in fixed words.
pub fn the_list_says_when_it_indexes_and_when_it_stopped_test() {
  let waiting =
    opened(silent(process.new_subject(), None))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  assert string.contains(drawn(waiting), "Indexing your folders…")

  let stopped =
    opened(owner(
      process.new_subject(),
      Ok(Index("/Users/o", [Entry(["a", "loomy"], "loomy")], Stopped)),
    ))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  assert string.contains(drawn(stopped), "Not every folder was searched.")

  let refused =
    opened(owner(process.new_subject(), Error(folder_browse.Unreadable)))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  assert string.contains(drawn(refused), "took too long to build")

  let empty =
    opened(owner(process.new_subject(), Ok(Index("/Users/o", [], Covered))))
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("zzzz"),
    ])
  assert string.contains(drawn(empty), "Nothing matches that search.")
}

// A page whose daemon gave it no folder capability asks for nothing and does not
// say it is indexing.
pub fn a_page_without_the_capability_never_indexes_test() {
  let start =
    home.Start(
      ..owner(process.new_subject(), Ok(Index("/h", [], Covered))),
      folders: None,
    )
  let model =
    opened(start)
    |> pressing([
      composer.Toggled(composer.CodeChip),
      composer.Searched("loom"),
    ])
  assert !string.contains(drawn(model), "Indexing")
}

// Pressing a found folder chooses it, and the creation is asked for the typed
// path the daemon judges.
pub fn a_found_folder_reaches_the_daemon_as_a_typed_path_test() {
  let model =
    opened(owner(
      process.new_subject(),
      Ok(Index(
        "/Users/o",
        [Entry(["code", "loom-picker"], "loom-picker")],
        Covered,
      )),
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
      Ok(Index("/Users/o", [Entry(["a", "loomy"], "loomy")], Covered)),
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

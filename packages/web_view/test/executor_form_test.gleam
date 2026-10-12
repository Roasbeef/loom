//// Creating a session on an executor or in a pool from the home page
//// (protocol-change/078, 085).
////
//// The owner's page gains a panel beside the form for a typed folder: a card for
//// each executor and each pool the daemon gave the page, with the state the
//// daemon found when the panel opened, and, for the card that is chosen, a form
//// for the name the workspace is registered under there and an optional session
//// name. These tests pin what the panel offers and when, what a choice and a
//// submit ask the daemon for, how the browser's fields decode, and how a remote
//// session is listed.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element
import web_view/creations
import web_view/home
import web_view/placements
import web_view/sessions.{type Entry, Entry, Saved}
import web_view/signins
import web_view/view/create

fn entry(
  id: String,
  name: String,
  workspace: String,
  created_at: Int,
) -> Entry {
  Entry(
    id:,
    name:,
    workspace:,
    created_at:,
    residency: Saved,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn on(entry: Entry, executor: String) -> Entry {
  Entry(..entry, executor: Some(executor))
}

fn page(
  rows: List(Entry),
  executors: List(String),
  pools: List(String),
  read: fn(fn(placements.Read) -> Nil) -> Nil,
  create: Option(
    fn(
      creations.Place,
      String,
      creations.Sharing,
      creations.Roles,
      fn(creations.Answer) -> Nil,
    ) -> Nil,
  ),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(rows)) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 7_400_000 },
    activity: fn(_, _) { Nil },
    rename: None,
    manage: None,
    create:,
    folders: None,
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
    executors:,
    pools:,
    placements: read,
  )
}

// A read that never answers, as a daemon still connecting to its executors.
fn pending(_deliver: fn(placements.Read) -> Nil) -> Nil {
  Nil
}

// A page that may create, whose every creation is heard with the place, the
// name, the sharing and the roles it carried, and whose placements read has not
// answered.
fn executing(
  rows: List(Entry),
  executors: List(String),
  asked: Subject(#(creations.Place, String, creations.Sharing, creations.Roles)),
) -> home.Start {
  hearing(rows, executors, [], pending, asked)
}

fn hearing(
  rows: List(Entry),
  executors: List(String),
  pools: List(String),
  read: fn(fn(placements.Read) -> Nil) -> Nil,
  asked: Subject(#(creations.Place, String, creations.Sharing, creations.Roles)),
) -> home.Start {
  page(
    rows,
    executors,
    pools,
    read,
    Some(fn(place, name, sharing, roles, _) {
      process.send(asked, #(place, name, sharing, roles))
    }),
  )
}

// What the daemon reports for one executor.
fn report(state: placements.State) -> placements.Report {
  placements.Report(state:, platform: None, enforcement: None, toolchains: [])
}

// A daemon's answer: `box` is ready and declares a platform, `gpu` is down, and
// the pool `builders` admits both, with only `box` reached.
fn reported() -> placements.Read {
  placements.Reported(
    placements.Placements(
      executors: [
        placements.Executor(
          "box",
          Some(
            placements.Report(
              ..report(placements.Ready),
              platform: Some("linux/x86_64"),
              enforcement: Some("enforced"),
              toolchains: ["codemode"],
            ),
          ),
        ),
        placements.Executor("gpu", Some(report(placements.Down))),
      ],
      pools: [
        placements.Pool(
          "builders",
          Some(
            placements.PoolReport(executors: ["gpu", "box"], eligible: ["box"]),
          ),
        ),
      ],
    ),
  )
}

fn answering(read: placements.Read) -> fn(fn(placements.Read) -> Nil) -> Nil {
  fn(deliver) { deliver(read) }
}

// Runs one message through the component and folds back what its effects
// dispatch, as Lustre's runtime would.
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

fn the_asked(
  asked: Subject(#(creations.Place, String, creations.Sharing, creations.Roles)),
) -> Result(#(creations.Place, String, creations.Sharing, creations.Roles), Nil) {
  process.receive(asked, 0)
}

// The panel is offered only where the daemon gave an executor or a pool and the
// page may create, and draws a card for each, in the configuration's order,
// executors first. Until the daemon answers the cards carry names alone.
pub fn the_panel_is_offered_only_when_there_is_somewhere_to_run_test() {
  let asked = process.new_subject()
  let none = opened(executing([], [], asked))
  assert !string.contains(drawn(none), "on an executor")
  let none = run(none, home.OpeningRemote)
  assert !string.contains(drawn(none), "home-cards")

  let listed =
    opened(hearing([], ["build-box", "gpu"], ["builders"], pending, asked))
  assert string.contains(drawn(listed), "New session on an executor")
  assert !string.contains(drawn(listed), "home-cards")
  let html = drawn(run(listed, home.OpeningRemote))
  assert string.contains(html, "home-cards")
  assert string.contains(
    html,
    "<span class=\"home-card-name\">build-box</span>",
  )
  assert string.contains(html, "<span class=\"home-card-name\">gpu</span>")
  assert string.contains(html, "<span class=\"home-card-name\">builders</span>")
  assert string.contains(html, "<span class=\"home-card-kind\">pool</span>")
  assert string.contains(html, "not checked")
  assert string.contains(html, "Checking which are reachable")

  // No form until a card is chosen, and no executor select ever.
  assert !string.contains(html, "name=\"workspace\"")
  assert !string.contains(html, "name=\"executor\"")

  // A pool alone is somewhere to run.
  let pooled = opened(hearing([], [], ["builders"], pending, asked))
  assert string.contains(drawn(pooled), "New session on an executor")

  // A page that may not create offers nothing whatever the daemon listed.
  let member = opened(page([], ["build-box"], [], pending, None))
  assert !string.contains(drawn(member), "on an executor")
  let member = run(member, home.OpeningRemote)
  assert !string.contains(drawn(member), "home-cards")
}

// The daemon's answer puts a state pill on each card, in the tints the page
// already has, with what it knows of the executor, and says the state is advice.
pub fn the_cards_show_the_state_the_daemon_found_test() {
  let asked = process.new_subject()
  let start =
    hearing([], ["box", "gpu"], ["builders"], answering(reported()), asked)
  let html = drawn(run(opened(start), home.OpeningRemote))
  assert string.contains(html, "<span class=\"pill online\">ready</span>")
  assert string.contains(html, "<span class=\"pill ended\">down</span>")
  assert string.contains(html, "Declared: linux/x86_64, enforced, codemode.")
  assert string.contains(html, "Declares nothing about its machine.")
  assert string.contains(
    html,
    "1 of 2 executors reachable. Tried in order: gpu, box.",
  )
  assert string.contains(html, "A state is advice")
  assert !string.contains(html, "not checked")
  assert !string.contains(html, "Checking which are reachable")
}

// While the daemon's read is out the cards carry names alone, and a person can
// still choose one: a state is advice and its absence blocks nothing.
pub fn a_card_is_choosable_before_the_read_arrives_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box"], [], pending, asked)
  let model = run(opened(start), home.OpeningRemote)
  assert string.contains(drawn(model), "not checked")
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  assert string.contains(drawn(model), "name=\"workspace\"")
}

// Choosing a card draws the form for it and nothing sends a creation until the
// form is submitted. A down executor is a choice like any other.
pub fn choosing_a_card_opens_the_form_for_it_even_when_it_is_down_test() {
  let asked = process.new_subject()
  let start =
    hearing([], ["box", "gpu"], ["builders"], answering(reported()), asked)
  let model = run(opened(start), home.OpeningRemote)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("gpu")))
  let html = drawn(model)
  assert string.contains(html, "name=\"workspace\"")
  assert string.contains(html, "The session will run on executor ")
  assert string.contains(html, "<b>gpu</b>")
  assert string.contains(html, "Chosen")
  assert the_asked(asked) == Error(Nil)

  // Choosing another card moves the choice.
  let model = run(model, home.ChoosingPlace(placements.InPool("builders")))
  let html = drawn(model)
  assert string.contains(html, "The session will run in pool ")
  assert string.contains(html, "<b>builders</b>")
  assert !string.contains(html, "<b>gpu</b>")
}

// A submit asks the daemon for a registered place under the name typed, as a
// shareable session (a session on an executor is session-only), and the panel is
// locked until the answer arrives. The form draws no profile or model select, so
// the roles are the configuration's own even when the page offers both.
pub fn a_creation_names_the_executor_and_the_workspace_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let model = run(model, home.CreatingRemote("app", "review"))
  assert the_asked(asked)
    == Ok(#(
      creations.Registered("build-box", "app"),
      "review",
      creations.Shareable,
      creations.default_roles,
    ))
  let html = drawn(model)
  assert string.contains(html, "Creating")
  assert string.contains(html, "disabled")

  // A second submit while the first is out asks nothing.
  let _ = run(model, home.CreatingRemote("app", "again"))
  assert the_asked(asked) == Error(Nil)
}

// A pool chosen asks the daemon for a pooled place, which the daemon turns into
// a session whose executor is picked when it first opens.
pub fn a_creation_in_a_pool_names_the_pool_and_the_workspace_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box"], ["builders"], answering(reported()), asked)
  let model = run(opened(start), home.OpeningRemote)
  let model = run(model, home.ChoosingPlace(placements.InPool("builders")))
  let _ = run(model, home.CreatingRemote("app", ""))
  assert the_asked(asked)
    == Ok(#(
      creations.Pooled("builders", "app"),
      "",
      creations.Shareable,
      creations.default_roles,
    ))
}

// A page that offers profiles and models on its other forms still draws neither
// on the registered form, and a registered session asks for the configuration's
// own roles. The model select is for local folders; a registered session's model
// can be pinned from the control command.
pub fn the_registered_form_offers_no_profile_or_model_test() {
  let asked = process.new_subject()
  let start =
    home.Start(
      ..executing([], ["build-box"], asked),
      profiles: ["alt"],
      models: ["fast"],
    )
  let model = run(opened(start), home.OpeningRemote)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let html = drawn(model)
  assert string.contains(html, "name=\"workspace\"")
  assert !string.contains(html, "name=\"profile\"")
  assert !string.contains(html, "name=\"model\"")

  let _ = run(model, home.CreatingRemote("app", ""))
  assert the_asked(asked)
    == Ok(#(
      creations.Registered("build-box", "app"),
      "",
      creations.Shareable,
      creations.default_roles,
    ))
}

// The page asks only from the open form, and only for a placement a card it drew
// chose, so a submit with no choice, a choice of a card the page did not draw and
// a choice of an executor under a pool's name all ask nothing.
pub fn a_placement_the_daemon_did_not_list_asks_nothing_test() {
  let asked = process.new_subject()
  let start =
    hearing([], ["build-box"], ["builders"], answering(reported()), asked)
  let model = opened(start)
  let _ = run(model, home.CreatingRemote("app", ""))
  assert the_asked(asked) == Error(Nil)

  // The panel is open and nothing is chosen: a submit asks nothing.
  let model = run(model, home.OpeningRemote)
  let _ = run(model, home.CreatingRemote("app", ""))
  assert the_asked(asked) == Error(Nil)

  // A choice outside the cards is not honoured, and neither is one that mixes
  // an executor's name with a pool's kind.
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("other")))
  let model = run(model, home.ChoosingPlace(placements.InPool("build-box")))
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("builders")))
  let _ = run(model, home.CreatingRemote("app", ""))
  assert the_asked(asked) == Error(Nil)
  assert !string.contains(drawn(model), "name=\"workspace\"")

  // A choice with no panel open is not honoured either.
  let closed = opened(start)
  let closed =
    run(closed, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let _ = run(closed, home.CreatingRemote("app", ""))
  assert the_asked(asked) == Error(Nil)
}

// The read is numbered: an answer that a newer read overtook is dropped, so a
// slow read cannot put an older state on a card.
pub fn a_stale_placement_answer_is_dropped_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box", "gpu"], [], pending, asked)
  let model = run(opened(start), home.OpeningRemote)

  // The first read is number one and has not answered. Close and reopen the
  // panel: the second read is number two.
  let model = run(model, home.Cancelled)
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.PlacementsRead(1, reported()))
  assert !string.contains(drawn(model), "pill online\">ready<")
  assert string.contains(drawn(model), "not checked")
  let model = run(model, home.PlacementsRead(2, reported()))
  assert string.contains(drawn(model), "pill online\">ready<")
}

// A page with no creation to offer takes no answer.
pub fn a_page_that_cannot_create_ignores_a_placement_answer_test() {
  let model = opened(page([], ["box"], [], pending, None))
  let model = run(model, home.PlacementsRead(0, reported()))
  assert !string.contains(drawn(model), "pill online\">ready<")
}

// One form is open at a time, and Cancel closes the panel.
pub fn the_panel_moves_with_the_other_forms_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.OpeningElsewhere)
  assert !string.contains(drawn(model), "home-cards")
  assert string.contains(drawn(model), "name=\"path\"")
  let model = run(model, home.OpeningRemote)
  assert !string.contains(drawn(model), "name=\"path\"")
  assert string.contains(drawn(model), "home-cards")
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let model = run(model, home.OpeningElsewhere)
  assert !string.contains(drawn(model), "home-cards")
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.Cancelled)
  assert !string.contains(drawn(model), "home-cards")
}

// A refusal puts the form back for a correction in fixed words, with the card
// still chosen, and a session made and not opened closes it and says why in the
// owner's own reason.
pub fn refusals_reopen_the_form_and_a_kept_session_closes_it_test() {
  assert creations.reason_words(creations.UnknownExecutor)
    == "That executor is not in the daemon's configuration now. Reload the page."
  assert creations.reason_words(creations.UnknownPool)
    == "That pool is not in the daemon's configuration now. Reload the page."
  assert string.contains(
    creations.reason_words(creations.InvalidWorkspaceName),
    "It is a name, not a path.",
  )

  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let model = run(model, home.CreatingRemote("app", ""))
  let model =
    run(model, home.Created(creations.Declined(creations.UnknownExecutor)))
  let html = drawn(model)
  assert string.contains(html, "That executor is not in the daemon")
  assert string.contains(html, "name=\"workspace\"")
  assert string.contains(html, "<b>build-box</b>")

  let model = run(model, home.CreatingRemote("app", ""))
  let model =
    run(
      model,
      home.Created(creations.Unstarted(
        why: Some("executor_unavailable: no executor named build-box"),
        remains: creations.InList,
      )),
    )
  let html = drawn(model)
  assert string.contains(html, "executor_unavailable: no executor named")
  assert !string.contains(html, "name=\"workspace\"")
}

// The form's fields decode totally: one workspace, one name, and nothing else.
// The placement is not a field, so a forged one is an extra field and refuses
// the event.
pub fn the_fields_decode_totally_test() {
  let fields = create.remote_fields
  assert fields([#("workspace", "app"), #("name", "")]) == Ok(#("app", ""))
  assert fields([#("name", "x"), #("workspace", "app")]) == Ok(#("app", "x"))

  // A missing, repeated or extra field refuses the event.
  assert fields([#("workspace", "app")]) == Error(Nil)
  assert fields([#("name", "")]) == Error(Nil)
  assert fields([]) == Error(Nil)
  assert fields([#("workspace", "a"), #("workspace", "b"), #("name", "")])
    == Error(Nil)
  assert fields([#("workspace", "a"), #("name", ""), #("name", "")])
    == Error(Nil)
  assert fields([#("workspace", "app"), #("name", ""), #("shareable", "on")])
    == Error(Nil)

  // An executor or a pool in the form is a forgery: the placement is the page's
  // own state.
  assert fields([#("workspace", "app"), #("name", ""), #("executor", "0")])
    == Error(Nil)
  assert fields([#("workspace", "app"), #("name", ""), #("pool", "builders")])
    == Error(Nil)

  // The other forms take no executor, so a forged one on them is refused.
  assert create.fields([#("name", "x"), #("executor", "0")]) == Error(Nil)
  assert create.typed_fields([
      #("path", "~/a"),
      #("name", ""),
      #("executor", "0"),
    ])
    == Error(Nil)
}

// A name the daemon gave is escaped as a text node and is in no attribute, on a
// card and in the form the card opens, whether it is an executor's, a pool's or
// text from the report.
pub fn a_name_is_a_text_node_and_never_an_attribute_test() {
  let hostile = "x\" onfocus=\"alert(1)\" <b>"
  let asked = process.new_subject()
  let read =
    placements.Reported(
      placements.Placements(
        executors: [
          placements.Executor(
            hostile,
            Some(
              placements.Report(
                ..report(placements.Ready),
                platform: Some(hostile),
              ),
            ),
          ),
        ],
        pools: [
          placements.Pool(
            hostile,
            Some(
              placements.PoolReport(executors: [hostile], eligible: [hostile]),
            ),
          ),
        ],
      ),
    )
  let model =
    run(
      opened(hearing([], [hostile], [hostile], answering(read), asked)),
      home.OpeningRemote,
    )
  let html = drawn(model)
  assert !string.contains(html, "onfocus=\"alert(1)\"")
  assert string.contains(html, "&lt;b&gt;")
  let model = run(model, home.ChoosingPlace(placements.OnExecutor(hostile)))
  let html = drawn(model)
  assert !string.contains(html, "onfocus=\"alert(1)\"")
  assert string.contains(html, "&lt;b&gt;")
}

// A registered name is a name and never a path.
pub fn a_registered_name_is_never_a_path_test() {
  assert creations.registered_name("  app ") == Ok("app")
  assert creations.registered_name("") == Error(Nil)
  assert creations.registered_name("   ") == Error(Nil)
  assert creations.registered_name("/work/app") == Error(Nil)
  assert creations.registered_name("a/b") == Error(Nil)
  assert creations.registered_name("a\nb") == Error(Nil)
  assert creations.registered_name(string.repeat("a", 129)) == Error(Nil)
  assert creations.registered_name(string.repeat("a", 128))
    == Ok(string.repeat("a", 128))
}

// A remote session is listed under its executor and name and not under a
// project directory, two executors that each register `app` are two groups, and
// a remote group has no "New session" button: the daemon would refuse a
// directory's creation in a name it holds no folder for.
pub fn a_remote_session_is_listed_under_its_executor_test() {
  let rows = [
    entry("L", "local work", "/src/loom", 2000),
    entry("R1", "remote work", "app", 1000) |> on("build-box"),
    entry("R2", "other work", "app", 900) |> on("gpu"),
  ]
  let asked = process.new_subject()
  let model = opened(executing(rows, ["build-box", "gpu"], asked))
  let html = drawn(model)
  assert string.contains(html, "build-box:app")
  assert string.contains(html, "gpu:app")
  assert string.contains(html, "remote work")
  assert list.length(home.groups(model)) == 3
  assert list.length(string.split(html, "New session</button>")) - 1 == 1
}

// A remote entry has no project and no worktree: its name is not a directory.
pub fn a_remote_entry_has_no_worktree_test() {
  let remote = entry("R", "n", "app", 0) |> on("box")
  assert sessions.project_of(remote) == "box:app"
  assert sessions.worktree(remote) == None
  assert sessions.project_of(entry("L", "n", "/src/app", 0)) == "/src/app"
}

//// Creating a session on an executor or in a pool from the home page
//// (protocol-change/078, 085).
////
//// Where the daemon has executors or pools the one "New session" form opens with
//// a "Runs on" choice: a card for this machine, chosen by default, and one for
//// each executor and each pool with the state the daemon found when the form
//// opened. For a chosen executor or pool the folder field gives way to a select
//// of the workspaces it registered, and an optional session name. These tests
//// pin what the choice offers and when, what a choice and a submit ask the
//// daemon for, how the browser's fields decode, and how a remote session is
//// listed.

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
    elsewhere: None,
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
    machine: "alpha",
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
  placements.Report(
    state:,
    platform: None,
    enforcement: None,
    toolchains: [],
    free_scopes: None,
    workspaces: [],
    contradiction: None,
  )
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
              workspaces: ["app", "tools"],
            ),
          ),
        ),
        placements.Executor("gpu", Some(report(placements.Down))),
      ],
      pools: [
        placements.Pool(
          "builders",
          Some(
            placements.PoolReport(
              executors: ["gpu", "box"],
              eligible: ["box"],
              workspaces: ["app", "tools"],
            ),
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

// The choice is offered only where the daemon gave an executor or a pool and the
// page may create. A single-machine daemon draws the folder form alone and none
// of the vocabulary, and the cards carry names alone until the daemon answers.
pub fn the_choice_is_offered_only_when_there_is_somewhere_to_run_test() {
  let asked = process.new_subject()
  let none = run(opened(executing([], [], asked)), home.OpeningElsewhere)
  let html = drawn(none)
  assert string.contains(html, "name=\"path\"")
  assert !string.contains(html, "Runs on")
  assert !string.contains(html, "home-cards")
  assert !string.contains(html, "this machine")
  assert !string.contains(html, "executor")

  let listed =
    opened(hearing([], ["build-box", "gpu"], ["builders"], pending, asked))
  assert !string.contains(drawn(listed), "home-cards")
  let html = drawn(run(listed, home.OpeningElsewhere))
  assert string.contains(html, "Runs on")
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

  // A pool alone is somewhere to run.
  let pooled = opened(hearing([], [], ["builders"], pending, asked))
  assert string.contains(drawn(run(pooled, home.OpeningElsewhere)), "Runs on")

  // A page that may not create offers nothing whatever the daemon listed.
  let member = opened(page([], ["build-box"], [], pending, None))
  let member = run(member, home.OpeningElsewhere)
  assert !string.contains(drawn(member), "home-cards")
  assert !string.contains(drawn(member), "Runs on")
}

// This machine is the first card, named for the daemon, chosen without a press,
// and the form under it is the folder form, as it was before the choice existed.
pub fn this_machine_is_the_default_choice_test() {
  let asked = process.new_subject()
  let start =
    hearing([], ["box", "gpu"], ["builders"], answering(reported()), asked)
  let html = drawn(run(opened(start), home.OpeningElsewhere))
  assert string.contains(html, "alpha (this machine)")
  assert string.contains(html, "Commands and the conversation stay on alpha.")
  assert string.contains(html, "name=\"path\"")
  assert !string.contains(html, "name=\"workspace\"")
  assert string.contains(html, "name=\"shareable\"")

  // This machine's card is the pressed one, and it is listed before the
  // executors.
  let assert [before, after] = string.split(html, "alpha (this machine)")
  assert string.contains(before, "home-card chosen")
  assert !string.contains(before, "home-card-kind")
  assert string.contains(after, "aria-pressed=\"true\"")
}

// The card for this machine carries the name the daemon was given for itself,
// the one its ledger uses for it, and not its node string.
pub fn this_machine_is_titled_by_the_name_the_daemon_gives_it_test() {
  let asked = process.new_subject()
  let start =
    home.Start(
      ..hearing([], ["box"], [], answering(reported()), asked),
      machine: "hub",
    )
  let html = drawn(run(opened(start), home.OpeningElsewhere))
  assert string.contains(html, "hub (this machine)")
  assert string.contains(html, "Commands and the conversation stay on hub.")
  assert !string.contains(html, "alpha (this machine)")
}

// The daemon's answer puts a state pill on each card, in the tints the page
// already has, with what it knows of the executor, and says the state is advice.
pub fn the_cards_show_the_state_the_daemon_found_test() {
  let asked = process.new_subject()
  let start =
    hearing([], ["box", "gpu"], ["builders"], answering(reported()), asked)
  let html = drawn(run(opened(start), home.OpeningElsewhere))
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

// While the daemon's read is out a card can be chosen, because a state is advice
// and its absence blocks nothing. The workspaces it registered are not known
// yet, so the form says so and takes the name as typed text.
pub fn a_card_is_choosable_before_the_read_arrives_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box"], [], pending, asked)
  let model = run(opened(start), home.OpeningElsewhere)
  assert string.contains(drawn(model), "not checked")
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let html = drawn(model)
  assert string.contains(
    html,
    "box has not reported its workspaces; type the name it serves.",
  )
  assert string.contains(
    html,
    "placeholder=\"Workspace name, for example app\"",
  )
  assert !string.contains(html, "<select name=\"workspace\"")
  assert string.contains(html, "Create session")
  assert string.contains(html, "name=\"name\"")
}

// Choosing an executor swaps the folder field for the workspaces it registered,
// says where the work happens, and sends nothing. A down executor is a choice
// like any other, though its workspaces are not known.
pub fn choosing_an_executor_offers_its_workspaces_test() {
  let asked = process.new_subject()
  let start =
    hearing([], ["box", "gpu"], ["builders"], answering(reported()), asked)
  let model = run(opened(start), home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let html = drawn(model)
  assert string.contains(html, "name=\"workspace\"")
  assert string.contains(html, "<option value=\"0\">app</option>")
  assert string.contains(html, "<option value=\"1\">tools</option>")
  assert !string.contains(html, "Workspace name, for example")
  assert !string.contains(html, "has not reported")
  assert !string.contains(html, "name=\"path\"")
  assert !string.contains(html, "name=\"shareable\"")
  assert string.contains(
    html,
    "Commands run on box (linux/x86_64); the conversation stays on alpha.",
  )
  assert the_asked(asked) == Error(Nil)

  let model = run(model, home.ChoosingPlace(placements.OnExecutor("gpu")))
  let html = drawn(model)
  assert string.contains(
    html,
    "gpu has not reported its workspaces; type the name it serves.",
  )
  assert !string.contains(html, "<select name=\"workspace\"")
  assert string.contains(html, "Create session")
  assert string.contains(html, "Commands run on gpu; the conversation")
  assert the_asked(asked) == Error(Nil)

  // Choosing this machine puts the folder form back.
  let model = run(model, home.ChoosingHere)
  let html = drawn(model)
  assert string.contains(html, "name=\"path\"")
  assert !string.contains(html, "has not reported")
}

// A place whose list is unknown submits the typed name: the creation names the
// executor and exactly the text the person typed, trimmed.
pub fn an_unknown_list_submits_the_typed_name_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["box"], asked))
  let model = run(model, home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let html = drawn(model)
  assert string.contains(html, "name=\"workspace\"")
  // The form's own decoder trims the typed text before the page sees it.
  let assert Ok(#(workspace, name, roles)) =
    create.remote_fields_with_roles(
      [#("workspace", " served "), #("name", "review")],
      [],
      [],
      [],
    )
  let _ = run(model, home.CreatingRemote(workspace, name, roles))
  assert the_asked(asked)
    == Ok(#(
      creations.Registered("box", "served"),
      "review",
      creations.Shareable,
      creations.default_roles,
    ))
}

// The submit is checked against what the form could have sent. Where the
// daemon listed the place's workspaces the form drew a select, so a name outside
// the list is refused and sends nothing. Where it listed none the form drew a
// text field, and a name that cannot be a workspace name is refused too.
pub fn a_workspace_the_form_could_not_have_sent_is_refused_test() {
  let asked = process.new_subject()
  let listed = hearing([], ["box"], ["builders"], answering(reported()), asked)
  let model = run(opened(listed), home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let _ =
    run(model, home.CreatingRemote("elsewhere", "", creations.default_roles))
  assert the_asked(asked) == Error(Nil)
  let _ = run(model, home.CreatingRemote("tools", "", creations.default_roles))
  assert the_asked(asked)
    == Ok(#(
      creations.Registered("box", "tools"),
      "",
      creations.Shareable,
      creations.default_roles,
    ))

  // A pool offers the names its reached executors share.
  let pooled = run(model, home.ChoosingPlace(placements.InPool("builders")))
  let _ =
    run(pooled, home.CreatingRemote("elsewhere", "", creations.default_roles))
  assert the_asked(asked) == Error(Nil)

  let unread = opened(executing([], ["box"], asked))
  let unread = run(unread, home.OpeningElsewhere)
  let unread = run(unread, home.ChoosingPlace(placements.OnExecutor("box")))
  let _ =
    run(unread, home.CreatingRemote("/work/app", "", creations.default_roles))
  assert the_asked(asked) == Error(Nil)
  let _ = run(unread, home.CreatingRemote("", "", creations.default_roles))
  assert the_asked(asked) == Error(Nil)
}

// The daemon's refusal of a name the executor does not serve comes back on the
// form, in the executor's own words, and the typed field is still there to
// correct.
pub fn a_refusal_for_an_unknown_name_renders_on_the_form_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["box"], asked))
  let model = run(model, home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let model =
    run(model, home.CreatingRemote("nope", "", creations.default_roles))
  let model =
    run(model, home.Created(creations.Declined(creations.InvalidWorkspaceName)))
  let html = drawn(model)
  assert string.contains(
    html,
    creations.reason_words(creations.InvalidWorkspaceName),
  )
  assert string.contains(
    html,
    "placeholder=\"Workspace name, for example app\"",
  )
  assert string.contains(html, "Create session")

  // A refusal that arrives as a start failure names the executor's own words.
  let model =
    run(model, home.CreatingRemote("nope", "", creations.default_roles))
  let model =
    run(
      model,
      home.Created(creations.Unstarted(
        why: Some("executor serves no workspace named `nope`"),
        remains: creations.Dropped,
      )),
    )
  let html = drawn(model)
  assert string.contains(html, "executor serves no workspace named")
  assert string.contains(
    html,
    "placeholder=\"Workspace name, for example app\"",
  )
}

// A pool offers the workspaces every executor it could use has registered, and
// says the daemon picks the executor.
pub fn choosing_a_pool_offers_the_shared_workspaces_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box"], ["builders"], answering(reported()), asked)
  let model = run(opened(start), home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.InPool("builders")))
  let html = drawn(model)
  assert string.contains(html, "<option value=\"0\">app</option>")
  assert string.contains(
    html,
    "The daemon picks the executor from pool builders",
  )
}

// A submit asks the daemon for a registered place under the name picked, as a
// shareable session (a session on an executor is session-only), and the form is
// locked until the answer arrives.
pub fn a_creation_names_the_executor_and_the_workspace_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let model =
    run(model, home.CreatingRemote("app", "review", creations.default_roles))
  assert the_asked(asked)
    == Ok(#(
      creations.Registered("build-box", "app"),
      "review",
      creations.Shareable,
      creations.default_roles,
    ))
  assert string.contains(drawn(model), "disabled")

  // A second submit while the first is out asks nothing.
  let _ =
    run(model, home.CreatingRemote("app", "again", creations.default_roles))
  assert the_asked(asked) == Error(Nil)
}

// A pool chosen asks the daemon for a pooled place, which the daemon turns into
// a session whose executor is picked when it first opens.
pub fn a_creation_in_a_pool_names_the_pool_and_the_workspace_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box"], ["builders"], answering(reported()), asked)
  let model = run(opened(start), home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.InPool("builders")))
  let _ = run(model, home.CreatingRemote("app", "", creations.default_roles))
  assert the_asked(asked)
    == Ok(#(
      creations.Pooled("builders", "app"),
      "",
      creations.Shareable,
      creations.default_roles,
    ))
}

// The profile and the model are choices on the registered form as well. A pick
// is carried to the creation only if it is one the page offered, and the form
// says how the two combine.
pub fn the_registered_form_offers_the_profile_and_the_model_test() {
  let asked = process.new_subject()
  let start =
    home.Start(
      ..hearing([], ["box"], [], answering(reported()), asked),
      profiles: ["alt"],
      models: ["fast"],
    )
  let model = run(opened(start), home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let html = drawn(model)
  assert string.contains(html, "name=\"profile\"")
  assert string.contains(html, "name=\"model\"")
  assert string.contains(html, "replaces the main model the profile gives")

  let picked = creations.Roles(Some("alt"), Some("fast"))
  let _ = run(model, home.CreatingRemote("app", "", picked))
  assert the_asked(asked)
    == Ok(#(creations.Registered("box", "app"), "", creations.Shareable, picked))

  // A profile the page never offered asks nothing.
  let _ =
    run(model, home.CreatingRemote("app", "", creations.Roles(Some("x"), None)))
  assert the_asked(asked) == Error(Nil)
}

// A daemon that defines neither draws neither select nor the line about them.
pub fn no_roles_are_drawn_when_the_daemon_defines_none_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box"], [], answering(reported()), asked)
  let model = run(opened(start), home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let html = drawn(model)
  assert !string.contains(html, "name=\"profile\"")
  assert !string.contains(html, "name=\"model\"")
  assert !string.contains(html, "replaces the main model")
}

// The page asks only from the open form, and only for a placement a card it drew
// chose, so a submit with no choice, a choice of a card the page did not draw and
// a choice of an executor under a pool's name all ask nothing.
pub fn a_placement_the_daemon_did_not_list_asks_nothing_test() {
  let asked = process.new_subject()
  let start =
    hearing([], ["build-box"], ["builders"], answering(reported()), asked)
  let model = opened(start)
  let none = creations.default_roles
  let _ = run(model, home.CreatingRemote("app", "", none))
  assert the_asked(asked) == Error(Nil)

  // The form is open on this machine: a registered submit asks nothing.
  let model = run(model, home.OpeningElsewhere)
  let _ = run(model, home.CreatingRemote("app", "", none))
  assert the_asked(asked) == Error(Nil)

  // A choice outside the cards is not honoured, and neither is one that mixes
  // an executor's name with a pool's kind.
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("other")))
  let model = run(model, home.ChoosingPlace(placements.InPool("build-box")))
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("builders")))
  let _ = run(model, home.CreatingRemote("app", "", none))
  assert the_asked(asked) == Error(Nil)
  assert !string.contains(drawn(model), "name=\"workspace\"")

  // A choice with no form open is not honoured either.
  let closed = opened(start)
  let closed =
    run(closed, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let _ = run(closed, home.CreatingRemote("app", "", none))
  assert the_asked(asked) == Error(Nil)
}

// The read is numbered: an answer that a newer read overtook is dropped, so a
// slow read cannot put an older state on a card.
pub fn a_stale_placement_answer_is_dropped_test() {
  let asked = process.new_subject()
  let start = hearing([], ["box", "gpu"], [], pending, asked)
  let model = run(opened(start), home.OpeningElsewhere)

  // The first read is number one and has not answered. Close and reopen the
  // form: the second read is number two.
  let model = run(model, home.Cancelled)
  let model = run(model, home.OpeningElsewhere)
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

// One form is open at a time. Pressing "New session" again keeps the choice
// made, another workspace's button moves the form, and Cancel closes it.
pub fn the_form_moves_with_the_other_forms_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningElsewhere)
  assert string.contains(drawn(model), "name=\"path\"")
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("build-box")))
  let model = run(model, home.OpeningElsewhere)
  assert string.contains(drawn(model), "Commands run on build-box")
  assert !string.contains(drawn(model), "name=\"path\"")
  let model = run(model, home.Choosing("/src/loom"))
  assert !string.contains(drawn(model), "home-cards")
  let model = run(model, home.OpeningElsewhere)
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
  let start = hearing([], ["box"], [], answering(reported()), asked)
  let none = creations.default_roles
  let model = run(opened(start), home.OpeningElsewhere)
  let model = run(model, home.ChoosingPlace(placements.OnExecutor("box")))
  let model = run(model, home.CreatingRemote("app", "", none))
  let model =
    run(model, home.Created(creations.Declined(creations.UnknownExecutor)))
  let html = drawn(model)
  assert string.contains(html, "That executor is not in the daemon")
  assert string.contains(html, "name=\"workspace\"")
  assert string.contains(html, "Commands run on box")

  let model = run(model, home.CreatingRemote("app", "", none))
  let model =
    run(
      model,
      home.Created(creations.Unstarted(
        why: Some("executor_unavailable: no executor named box"),
        remains: creations.InList,
      )),
    )
  let html = drawn(model)
  assert string.contains(html, "executor_unavailable: no executor named")
  assert !string.contains(html, "name=\"workspace\"")
}

// The form's fields decode totally: one workspace picked by position from the
// list the page drew, one name, and nothing else. The placement is not a field,
// so a forged one is an extra field and refuses the event.
pub fn the_fields_decode_totally_test() {
  let offered = ["app", "tools"]
  let fields = fn(listed) { create.remote_fields(listed, offered) }
  assert fields([#("workspace", "0"), #("name", "")]) == Ok(#("app", ""))
  assert fields([#("name", "x"), #("workspace", "1")]) == Ok(#("tools", "x"))

  // A text that is not a position of the list refuses the event, so the browser
  // can name only a workspace the page drew.
  assert fields([#("workspace", "app"), #("name", "")]) == Error(Nil)
  assert fields([#("workspace", "2"), #("name", "")]) == Error(Nil)
  assert fields([#("workspace", "-1"), #("name", "")]) == Error(Nil)
  assert fields([#("workspace", ""), #("name", "")]) == Error(Nil)

  // With no list the value is typed text, held to the grammar the daemon
  // applies to a registered name (`creations.registered_name`).
  let typed = fn(text) {
    create.remote_fields([#("workspace", text), #("name", "")], [])
  }
  assert typed(" app ") == Ok(#("app", ""))
  assert typed("") == Error(Nil)
  assert typed("/work/app") == Error(Nil)
  assert typed("a/b") == Error(Nil)
  assert typed("a\nb") == Error(Nil)
  assert typed(string.repeat("a", 129)) == Error(Nil)

  // A missing, repeated or extra field refuses the event.
  assert fields([#("workspace", "0")]) == Error(Nil)
  assert fields([#("name", "")]) == Error(Nil)
  assert fields([]) == Error(Nil)
  assert fields([#("workspace", "0"), #("workspace", "1"), #("name", "")])
    == Error(Nil)
  assert fields([#("workspace", "0"), #("name", ""), #("name", "")])
    == Error(Nil)
  assert fields([#("workspace", "0"), #("name", ""), #("shareable", "on")])
    == Error(Nil)

  // An executor or a pool in the form is a forgery: the placement is the page's
  // own state.
  assert fields([#("workspace", "0"), #("name", ""), #("executor", "0")])
    == Error(Nil)
  assert fields([#("workspace", "0"), #("name", ""), #("pool", "builders")])
    == Error(Nil)

  // The roles read as they do on the other forms.
  assert create.remote_fields_with_roles(
      [#("workspace", "1"), #("name", ""), #("profile", "0"), #("model", "")],
      offered,
      ["alt"],
      ["fast"],
    )
    == Ok(#("tools", "", creations.Roles(Some("alt"), None)))
  assert create.remote_fields_with_roles(
      [#("workspace", "1"), #("name", ""), #("model", "3")],
      offered,
      [],
      ["fast"],
    )
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
// card and in the form the card opens, whether it is an executor's, a pool's, a
// workspace's or text from the report.
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
                workspaces: [hostile],
              ),
            ),
          ),
        ],
        pools: [
          placements.Pool(
            hostile,
            Some(
              placements.PoolReport(
                executors: [hostile],
                eligible: [hostile],
                workspaces: [hostile],
              ),
            ),
          ),
        ],
      ),
    )
  let model =
    run(
      opened(hearing([], [hostile], [hostile], answering(read), asked)),
      home.OpeningElsewhere,
    )
  let html = drawn(model)
  assert !string.contains(html, "onfocus=\"alert(1)\"")
  assert string.contains(html, "&lt;b&gt;")
  let model = run(model, home.ChoosingPlace(placements.OnExecutor(hostile)))
  let html = drawn(model)
  assert !string.contains(html, "onfocus=\"alert(1)\"")
  assert string.contains(html, "&lt;b&gt;")
  assert string.contains(html, "<option value=\"0\">")
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
// a remote group has no "New session" button of its own: the daemon would refuse a
// directory's creation in a name it holds no folder for. The two buttons that
// remain are the local group's and the one in the folders section.
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
  assert list.length(string.split(html, "New session</button>")) - 1 == 2
}

// A remote entry has no project and no worktree: its name is not a directory.
pub fn a_remote_entry_has_no_worktree_test() {
  let remote = entry("R", "n", "app", 0) |> on("box")
  assert sessions.project_of(remote) == "box:app"
  assert sessions.worktree(remote) == None
  assert sessions.project_of(entry("L", "n", "/src/app", 0)) == "/src/app"
}

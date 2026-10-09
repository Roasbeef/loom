//// Creating a session on an executor from the home page (protocol-change/078).
////
//// The owner's page gains a form beside the one for a typed folder: an executor
//// chosen from the names the daemon gave the page, the name the workspace is
//// registered under there, and an optional session name. These tests pin what
//// the form offers and when, what a submit asks the daemon for, how the
//// browser's fields decode, and how a remote session is listed.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element
import web_view/creations
import web_view/home
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
  )
}

// A page that may create, whose every creation is heard with the place, the
// name and the sharing it carried.
fn executing(
  rows: List(Entry),
  executors: List(String),
  asked: Subject(#(creations.Place, String, creations.Sharing)),
) -> home.Start {
  page(
    rows,
    executors,
    Some(fn(place, name, sharing, _, _) {
      process.send(asked, #(place, name, sharing))
    }),
  )
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

// The form is offered only where the daemon has executors and the page may
// create, and draws each executor as an option whose value is its position.
pub fn the_form_is_offered_only_when_executors_exist_test() {
  let asked = process.new_subject()
  let none = opened(executing([], [], asked))
  assert !string.contains(drawn(none), "on an executor")
  let none = run(none, home.OpeningRemote)
  assert !string.contains(drawn(none), "name=\"executor\"")

  let listed = opened(executing([], ["build-box", "gpu"], asked))
  assert string.contains(drawn(listed), "New session on an executor")
  assert !string.contains(drawn(listed), "name=\"executor\"")
  let html = drawn(run(listed, home.OpeningRemote))
  assert string.contains(html, "name=\"executor\"")
  assert string.contains(html, "<option value=\"0\">build-box</option>")
  assert string.contains(html, "<option value=\"1\">gpu</option>")
  assert string.contains(html, "name=\"workspace\"")
  assert string.contains(html, "not a folder")

  // A page that may not create offers nothing whatever the daemon listed.
  let member = opened(page([], ["build-box"], None))
  assert !string.contains(drawn(member), "on an executor")
  let member = run(member, home.OpeningRemote)
  assert !string.contains(drawn(member), "name=\"executor\"")
}

// A submit asks the daemon for a registered place under the name typed, as a
// shareable session (a session on an executor is session-only), and the form is
// locked until the answer arrives.
pub fn a_creation_names_the_executor_and_the_workspace_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.CreatingRemote("build-box", "app", "review"))
  assert process.receive(asked, 0)
    == Ok(#(
      creations.Registered("build-box", "app"),
      "review",
      creations.Shareable,
    ))
  assert string.contains(drawn(model), "Creating")

  // A second submit while the first is out asks nothing.
  let _ = run(model, home.CreatingRemote("build-box", "app", "again"))
  assert process.receive(asked, 0) == Error(Nil)
}

// The page asks only from the open form, and only for an executor it was told
// of, so a message that names another executor, or arrives with no form open,
// asks nothing.
pub fn an_executor_the_daemon_did_not_list_asks_nothing_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let _ = run(model, home.CreatingRemote("build-box", "app", ""))
  assert process.receive(asked, 0) == Error(Nil)

  let model = run(model, home.OpeningRemote)
  let model = run(model, home.CreatingRemote("other", "app", ""))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "name=\"executor\"")
}

// One form is open at a time, and Cancel closes it.
pub fn the_form_moves_with_the_other_forms_test() {
  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.OpeningElsewhere)
  assert !string.contains(drawn(model), "name=\"executor\"")
  assert string.contains(drawn(model), "name=\"path\"")
  let model = run(model, home.OpeningRemote)
  assert !string.contains(drawn(model), "name=\"path\"")
  let model = run(model, home.Cancelled)
  assert !string.contains(drawn(model), "name=\"executor\"")
}

// A refusal puts the form back for a correction in fixed words, and a session
// made and not opened closes it and says why in the owner's own reason.
pub fn refusals_reopen_the_form_and_a_kept_session_closes_it_test() {
  assert creations.reason_words(creations.UnknownExecutor)
    == "That executor is not in the daemon's configuration now. Reload the page."
  assert string.contains(
    creations.reason_words(creations.InvalidWorkspaceName),
    "It is a name, not a path.",
  )

  let asked = process.new_subject()
  let model = opened(executing([], ["build-box"], asked))
  let model = run(model, home.OpeningRemote)
  let model = run(model, home.CreatingRemote("build-box", "app", ""))
  let model =
    run(model, home.Created(creations.Declined(creations.UnknownExecutor)))
  let html = drawn(model)
  assert string.contains(html, "That executor is not in the daemon")
  assert string.contains(html, "name=\"executor\"")

  let model = run(model, home.CreatingRemote("build-box", "app", ""))
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
  assert !string.contains(html, "name=\"executor\"")
}

// The form's fields decode totally: one executor given as a position in the
// list the page drew, one workspace, one name, and nothing else.
pub fn the_fields_decode_totally_test() {
  let offered = ["a", "b"]
  let fields = fn(listed) { create.remote_fields(listed, offered) }
  assert fields([#("executor", "1"), #("workspace", "app"), #("name", "")])
    == Ok(#("b", "app", ""))
  assert fields([#("name", "x"), #("workspace", "app"), #("executor", "0")])
    == Ok(#("a", "app", "x"))

  // A position outside the list, a negative one and a name where a position
  // goes name an executor the page did not draw.
  assert fields([#("executor", "2"), #("workspace", "app"), #("name", "")])
    == Error(Nil)
  assert fields([#("executor", "-1"), #("workspace", "app"), #("name", "")])
    == Error(Nil)
  assert fields([#("executor", "a"), #("workspace", "app"), #("name", "")])
    == Error(Nil)

  // A missing, repeated or extra field refuses the event.
  assert fields([#("workspace", "app"), #("name", "")]) == Error(Nil)
  assert fields([
      #("executor", "0"),
      #("executor", "1"),
      #("workspace", "app"),
      #("name", ""),
    ])
    == Error(Nil)
  assert fields([
      #("executor", "0"),
      #("workspace", "app"),
      #("name", ""),
      #("shareable", "on"),
    ])
    == Error(Nil)
  assert create.remote_fields(
      [#("executor", "0"), #("workspace", "app"), #("name", "")],
      [],
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

// An executor's name is the daemon's text: it is escaped as a text node and is
// in no attribute.
pub fn an_executor_name_is_a_text_node_and_never_an_attribute_test() {
  let hostile = "x\" onfocus=\"alert(1)\" <b>"
  let asked = process.new_subject()
  let model = opened(executing([], [hostile], asked))
  let html = drawn(run(model, home.OpeningRemote))
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

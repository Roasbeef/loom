//// The home page's new-session composer (`view/new_session`, `web_view/composer`
//// and the home component that joins them).
////
//// These tests pin the page the owner opens on: the composer, its chips and the
//// sentence; that a start asks the daemon once for the place the chips and the form
//// describe; that a choice the page did not draw is refused whichever way it
//// arrives; that a typed value is judged before it is sent; that unreachable
//// executors are disabled with a reason; that a page without the capability draws
//// no composer; the sidebar's filter pills and groups; and that every handler the
//// composer adds is beneath the region the owner's socket admits.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/composer
import web_view/creations
import web_view/home
import web_view/placements
import web_view/sessions.{type Entry, Entry, Live, Saved}
import web_view/signins
import web_view/view/new_session

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
    executor: None,
  )
}

fn on(entry: Entry, executor: String) -> Entry {
  Entry(..entry, executor: Some(executor))
}

fn rows() -> List(Entry) {
  [
    entry("B", "vetting lint", "/src/loom", 300_000, Live),
    entry("A", "web ui", "/src/loom", 100_000, Live),
    entry("C", "hex release", "/src/weft", 900_000, Saved),
    on(entry("R", "remote work", "repo", 800_000, Live), "exec"),
  ]
}

type Asked =
  Subject(
    #(creations.Place, String, creations.Sharing, creations.Roles, String),
  )

fn recording(
  asked: Asked,
) -> fn(
  creations.Place,
  String,
  creations.Sharing,
  creations.Roles,
  String,
  fn(creations.Answer) -> Nil,
) -> Nil {
  fn(place, name, sharing, roles, prompt, _) {
    process.send(asked, #(place, name, sharing, roles, prompt))
  }
}

fn report(
  state: placements.State,
  workspaces: List(String),
) -> placements.Report {
  placements.Report(
    state:,
    platform: None,
    enforcement: None,
    toolchains: [],
    free_scopes: None,
    workspaces:,
    contradiction: None,
  )
}

// The owner's page: it may create, the daemon has two executors and a pool, a
// profile and a model, and the placements read says `exec` has one workspace,
// `gpu` is down and the pool has nothing answering.
fn owner(asked: Asked) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(rows())) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 7_400_000 },
    activity: fn(_, deliver) {
      deliver([#("B", sessions.NeedsYou), #("A", sessions.Working)])
    },
    rename: None,
    manage: None,
    create: Some(recording(asked)),
    folders: None,
    elsewhere: None,
    profiles: ["fast"],
    models: ["glm"],
    signins: fn(deliver) { deliver(signins.Listed([])) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: Some(fn(_) { Nil }),
    who: fn(deliver) { deliver(None) },
    rename_self: None,
    visiting: None,
    orchestrators: None,
    executors: ["exec", "gpu"],
    pools: ["linux"],
    machine: "laptop",
    placements: fn(deliver) {
      deliver(
        placements.Reported(
          placements.Placements(
            executors: [
              placements.Executor(
                "exec",
                Some(report(placements.Ready, ["repo"])),
              ),
              placements.Executor("gpu", Some(report(placements.Down, []))),
            ],
            pools: [
              placements.Pool(
                "linux",
                Some(
                  placements.PoolReport(
                    executors: ["exec"],
                    eligible: [],
                    workspaces: [],
                  ),
                ),
              ),
            ],
          ),
        ),
      )
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

// The owner's page after its first read, on the composer where it opens.
fn opened(start: home.Start) -> home.Model {
  run(home.new(start), home.TimerReady(process.new_subject()))
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

fn compose(message: composer.Msg) -> home.Msg {
  home.Composed(message)
}

fn count(html: String, needle: String) -> Int {
  list.length(string.split(html, needle)) - 1
}

// The owner's page opens on the composer, with the chips and the sentence, the
// places a session worked in and the link to the old list.
pub fn the_owner_opens_on_the_composer_test() {
  let model = opened(owner(process.new_subject()))
  let html = drawn(model)

  assert string.contains(html, "What should the agent work on?")
  assert string.contains(html, "<h1>New session</h1>")
  assert string.contains(html, "Start again where you worked")
  assert string.contains(html, "Show the full session list")
  assert string.contains(
    html,
    "Agent</span><span class=\"place-chip-value\">laptop",
  )

  // The newest place a session worked in is in force before a choice is made, and
  // the sentence says so.
  assert string.contains(
    html,
    "Code</span><span class=\"place-chip-value\">/src/weft",
  )
  assert string.contains(html, "<b>/src/weft</b>")
  assert string.contains(
    html,
    "Model</span><span class=\"place-chip-value\">default",
  )
}

// A page that may not create, a member's or an observer-ceiling one, opens on the
// list and draws no composer, and the messages that would drive one change nothing.
pub fn a_page_without_the_capability_draws_no_composer_test() {
  let asked = process.new_subject()
  let start = home.Start(..owner(asked), create: None)
  let model = opened(start)
  let html = drawn(model)
  assert !string.contains(html, "What should the agent work on?")
  assert !string.contains(html, "composer")
  assert !string.contains(html, "New session</button>")

  let after = run(model, compose(composer.Started("x", composer.Nothing)))
  assert drawn(after) == html
  assert process.receive(asked, 0) == Error(Nil)
  assert drawn(run(model, home.ShowingNew)) == html
}

// A start asks the daemon once, for the place the chips chose, the name the form
// held and the roles the Model chip chose, and a second press while it is out asks
// nothing.
pub fn a_start_asks_the_daemon_once_for_the_chosen_place_test() {
  let asked = process.new_subject()
  let model = opened(owner(asked))
  let model = run(model, compose(composer.ChoseProfile(Some("fast"))))
  let model = run(model, compose(composer.ChoseModel(Some("glm"))))
  let model =
    run(model, compose(composer.ChoseTarget(composer.Folder("/src/weft"))))
  let model = run(model, compose(composer.Started("docs", composer.Nothing)))

  assert process.receive(asked, 0)
    == Ok(#(
      creations.Drawn("/src/weft"),
      "docs",
      creations.Private,
      creations.Roles(Some("fast"), Some("glm")),
      "docs",
    ))

  let model = run(model, compose(composer.Started("again", composer.Nothing)))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "Starting")
}

// The round trip a forged message takes: a target, a profile and a model that the
// page did not draw are refused, whichever way they arrive, and a start asks for
// the target that was chosen before them.
pub fn a_forged_choice_is_refused_and_never_asked_test() {
  let asked = process.new_subject()
  let model = opened(owner(asked))
  let before = drawn(model)

  let model = run(model, compose(composer.ChoseTarget(composer.Folder("/etc"))))
  let model =
    run(
      model,
      compose(composer.ChoseTarget(composer.OnExecutor("other", None))),
    )
  let model = run(model, compose(composer.ChoseProfile(Some("admin"))))
  let model = run(model, compose(composer.ChoseModel(Some("secret"))))
  assert drawn(model) == before

  let model = run(model, compose(composer.Started("x", composer.Nothing)))
  assert process.receive(asked, 0)
    == Ok(#(
      creations.Drawn("/src/weft"),
      "x",
      creations.Private,
      creations.default_roles,
      "x",
    ))
  assert !string.contains(drawn(model), "/etc")
}

// The code list: the folders, one section for each executor with what it
// reported, one for the pool, with an executor that is down disabled and saying
// why. Opening it owes a read of the placements, which the page performs.
pub fn the_code_list_has_folders_executors_and_pools_test() {
  let model = opened(owner(process.new_subject()))
  let model = run(model, compose(composer.Toggled(composer.CodeChip)))
  let html = drawn(model)

  assert string.contains(html, "aria-label=\"Where the code is\"")
  assert string.contains(html, "On laptop")
  assert string.contains(html, "/src/weft")
  assert string.contains(html, "Choose a folder…")

  // `exec` reported a workspace, and `gpu` is down: one disabled row, with the
  // reason in words.
  assert string.contains(html, "exec · repo")
  assert string.contains(html, "aria-disabled=\"true\"")
  assert string.contains(html, "Not answering")

  // The pool has no machine answering, and says so.
  assert string.contains(html, "Any of linux: exec")
  assert string.contains(html, "None answering")

  // The disabled rows are not buttons: only the rows that can work carry a press.
  assert count(html, "aria-disabled=\"true\"") == 2
}

// The owner's page with one executor, `exec`, and a pool `linux` whose report
// is the one given.
fn with_pool(pool: placements.PoolReport) -> home.Model {
  let start = owner(process.new_subject())
  let start =
    home.Start(..start, executors: ["exec"], placements: fn(deliver) {
      deliver(
        placements.Reported(
          placements.Placements(
            executors: [
              placements.Executor(
                "exec",
                Some(report(placements.Ready, ["repo", "repo-wt"])),
              ),
            ],
            pools: [placements.Pool("linux", Some(pool))],
          ),
        ),
      )
    })
  run(opened(start), compose(composer.Toggled(composer.CodeChip)))
}

// A pool whose only machine is an executor already drawn with the same
// workspaces adds no choice, so its section is not drawn.
pub fn a_pool_that_repeats_its_executor_is_not_drawn_test() {
  let html =
    drawn(
      with_pool(
        placements.PoolReport(
          executors: ["exec"],
          eligible: ["exec"],
          workspaces: ["repo", "repo-wt"],
        ),
      ),
    )

  assert string.contains(html, "exec · repo-wt")
  assert !string.contains(html, "linux ·")
  assert !string.contains(html, "linux pool")
  assert !string.contains(html, "Any of linux")
}

// A pool whose members are named says which, and one that the report only
// counts says how many and names none.
pub fn a_pool_heading_says_only_what_the_report_carries_test() {
  let named =
    drawn(
      with_pool(
        placements.PoolReport(
          executors: ["exec", "other"],
          eligible: ["exec", "other"],
          workspaces: ["repo"],
        ),
      ),
    )
  assert string.contains(named, "Any of linux: exec, other")

  let counted =
    drawn(
      with_pool(
        placements.PoolReport(
          executors: [],
          eligible: ["ready", "ready"],
          workspaces: ["repo", "repo-wt"],
        ),
      ),
    )
  assert string.contains(counted, "Any of 2 machines in linux")
  assert string.contains(counted, "linux · repo")

  let single =
    drawn(
      with_pool(
        placements.PoolReport(executors: [], eligible: ["ready"], workspaces: [
          "repo",
          "repo-wt",
        ]),
      ),
    )
  assert string.contains(single, "linux pool, 1 machine")
}

// The search narrows every section at once, and says when it matches nothing.
pub fn the_search_narrows_every_section_test() {
  let model = opened(owner(process.new_subject()))
  let model = run(model, compose(composer.Toggled(composer.CodeChip)))
  let model = run(model, compose(composer.Searched("weft")))
  let assert Ok(#(_, list_html)) =
    string.split_once(drawn(model), "aria-label=\"Where the code is\"")

  assert string.contains(list_html, "/src/weft")
  assert !string.contains(list_html, "exec · repo")
  assert !string.contains(list_html, "Choose a folder…")

  let model = run(model, compose(composer.Searched("zzz")))
  assert string.contains(drawn(model), "Nothing matches that search.")
}

// A workspace on an executor that reported one is chosen and asked as a registered
// place, and a name typed for one that reported none is judged first.
pub fn an_executors_workspace_is_asked_as_a_registered_place_test() {
  let asked = process.new_subject()
  let model = opened(owner(asked))
  let model = run(model, compose(composer.Toggled(composer.CodeChip)))
  let model =
    run(
      model,
      compose(composer.ChoseTarget(composer.OnExecutor("exec", Some("repo")))),
    )
  let model = run(model, compose(composer.Started("", composer.Nothing)))

  assert process.receive(asked, 0)
    == Ok(#(
      creations.Registered("exec", "repo"),
      "",
      creations.Private,
      creations.default_roles,
      "",
    ))
  // The page is waiting on the daemon, so it is not asked again.
  assert string.contains(drawn(model), "Starting")
}

// A typed workspace name must pass the registered-name rule, and a typed folder's
// path the path rule, before anything reaches the daemon.
pub fn typed_text_is_judged_before_the_daemon_is_asked_test() {
  let asked = process.new_subject()
  let model = opened(owner(asked))
  let model =
    run(model, compose(composer.ChoseTarget(composer.OnExecutor("gpu", None))))
  let model =
    run(model, compose(composer.Started("x", composer.Workspace("a/b"))))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "Name the workspace, or choose another.")

  let _ = run(model, compose(composer.Started("x", composer.Workspace("app"))))
  assert process.receive(asked, 0)
    == Ok(#(
      creations.Registered("gpu", "app"),
      "x",
      creations.Private,
      creations.default_roles,
      "x",
    ))
}

// The form carries exactly the fields it was drawn with: a name, and the one more
// the chosen target needs.
pub fn the_form_accepts_exactly_the_fields_it_was_drawn_with_test() {
  assert new_session.fields([#("prompt", "x")], new_session.NameOnly)
    == Ok(#("x", composer.Nothing))
  assert new_session.fields([#("prompt", "x")], new_session.NameAndPath)
    == Error(Nil)
  assert new_session.fields(
      [#("path", "~/a"), #("prompt", "x")],
      new_session.NameAndPath,
    )
    == Ok(#("x", composer.Path("~/a")))
  assert new_session.fields(
      [#("prompt", "x"), #("workspace", "w")],
      new_session.NameAndWorkspace,
    )
    == Ok(#("x", composer.Workspace("w")))

  // A repeated name, an executor field and an unknown field refuse the event.
  assert new_session.fields(
      [#("prompt", "x"), #("prompt", "y")],
      new_session.NameOnly,
    )
    == Error(Nil)
  assert new_session.fields(
      [#("prompt", "x"), #("executor", "exec")],
      new_session.NameOnly,
    )
    == Error(Nil)
  assert new_session.fields(
      [#("prompt", "x"), #("path", "/"), #("workspace", "w")],
      new_session.NameAndPath,
    )
    == Error(Nil)
}

// A target that needs a typed field draws that field, and every other draws only
// the name.
pub fn the_form_draws_the_field_its_target_needs_test() {
  let model = opened(owner(process.new_subject()))
  let plain = drawn(model)
  assert string.contains(plain, "name=\"prompt\"")
  assert !string.contains(plain, "name=\"path\"")
  assert !string.contains(plain, "name=\"workspace\"")

  let typed =
    drawn(run(model, compose(composer.ChoseTarget(composer.TypedFolder))))
  assert string.contains(typed, "name=\"path\"")
  assert string.contains(typed, "the folder you type")

  let named =
    drawn(run(
      model,
      compose(composer.ChoseTarget(composer.OnExecutor("gpu", None))),
    ))
  assert string.contains(named, "name=\"workspace\"")
}

// What the daemon refuses is worded on the form, in the reason's fixed words, and
// the page is ready again.
pub fn a_refusal_is_worded_on_the_form_test() {
  let model = opened(owner(process.new_subject()))
  let model = run(model, compose(composer.Started("x", composer.Nothing)))
  let model = run(model, home.Created(creations.Declined(creations.NotAFolder)))
  let html = drawn(model)
  assert string.contains(html, "new-refusal")
  assert string.contains(html, creations.reason_words(creations.NotAFolder))
  assert !string.contains(html, "Starting")
}

// A ticket departs for the new session through the hidden switch.
pub fn an_answered_start_departs_for_the_new_session_test() {
  let model = opened(owner(process.new_subject()))
  let model = run(model, compose(composer.Started("x", composer.Nothing)))
  let model =
    run(model, home.Created(creations.Ticketed("/ui/sessions/S?ticket=T")))
  assert string.contains(drawn(model), "/ui/sessions/S?ticket=T")
}

// Hostile text is drawn as text: a folder, an executor and a name the daemon
// listed never become a tag, an attribute or a class.
pub fn hostile_names_are_drawn_as_text_test() {
  let hostile = "<img src=x onerror=alert(1)>"
  let start =
    home.Start(
      ..owner(process.new_subject()),
      sessions: fn(deliver) {
        deliver(
          home.Listed([
            entry("H", hostile, "/src/" <> hostile, 1_000_000, Live),
          ]),
        )
      },
      profiles: [hostile],
      models: [hostile],
    )
  let model = opened(start)
  let model = run(model, compose(composer.Toggled(composer.CodeChip)))
  let html = drawn(model)
  assert !string.contains(html, "<img")
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")

  let model = run(model, compose(composer.Toggled(composer.ModelChip)))
  let html = drawn(model)
  assert !string.contains(html, "<img")
}

// The chips and every row are buttons beneath the region the owner's socket
// admits, the typed search is the one input, and the form's submit is beneath it.
pub fn every_composer_handler_is_beneath_the_table_region_test() {
  let model = opened(owner(process.new_subject()))
  let model = run(model, compose(composer.Toggled(composer.CodeChip)))
  let keys = handlers(home.view(model))

  let beneath = fn(key) {
    string.starts_with(key, home.table_path <> "\t")
    || string.starts_with(key, home.sidebar_path <> "\t")
    || string.starts_with(key, home.signins_path <> "\t")
    || string.starts_with(key, home.admin_path)
  }
  assert list.all(keys, beneath)

  // One input handler, the search's, and one submit, the form's.
  assert list.count(keys, string.ends_with(_, "\ninput")) == 1
  assert list.count(keys, string.ends_with(_, "\nsubmit")) == 1
}

// The sidebar groups the sessions by what each needs, tags each with the machine
// that runs the agent and where its code is, and offers a pill for a machine only
// when it tells rows apart.
pub fn the_sidebar_groups_tags_and_filters_test() {
  let model = opened(owner(process.new_subject()))
  let html = drawn(model)

  // `B` needs the owner, `A` is working, the other running ones are idle and
  // `C`, nothing runs, is behind the fold.
  assert string.contains(html, "state-needs-you")
  assert string.contains(html, "state-working")
  assert string.contains(html, "state-idle")
  assert string.contains(html, "1 saved")
  assert string.contains(html, "<span class=\"tag-agent\">laptop</span>")
  assert string.contains(html, "<span class=\"tag-code\">exec · repo</span>")

  // One executor is in use, so there is a pill for it and one for All; the
  // daemon's own would match every row and is not drawn.
  assert string.contains(html, "Show sessions on")
  assert string.contains(html, ">exec<span class=\"fp-count\">1</span>")
  assert !string.contains(html, ">laptop<span class=\"fp-count\"")

  // A press narrows the list; a name no pill carries does not.
  let narrowed = run(model, home.Narrowing("exec"))
  assert string.contains(
    drawn(narrowed),
    "aria-pressed=\"true\" class=\"fp\" type=\"button\">exec",
  )
  assert drawn(run(model, home.Narrowing("gpu"))) == html
  assert drawn(run(narrowed, home.Widening)) == html
}

// The owner's page counts the sessions waiting on a decision on the frame, for
// the phone's menu button, and draws the banner that names the first.
pub fn the_phone_banner_names_the_session_that_needs_the_owner_test() {
  let html = drawn(opened(owner(process.new_subject())))
  assert string.contains(html, "waiting=\"1\"")
  assert string.contains(html, "vetting lint needs you")
  assert string.contains(html, "class=\"banner\"")
}

// The sidebar's "New session" returns to the composer from the list, and the list
// link shows the older page.
pub fn the_sidebar_and_the_link_switch_between_the_composer_and_the_list_test() {
  let model = opened(owner(process.new_subject()))
  let listed = run(model, home.ShowingList)
  assert !string.contains(drawn(listed), "What should the agent work on?")
  assert string.contains(drawn(listed), "Other folders")

  let back = run(listed, home.ShowingNew)
  assert string.contains(drawn(back), "What should the agent work on?")
}

// The box is the session's first message. A start asks the daemon for the place
// the chips chose, the name the message's first line gives, and the message
// itself, once, and a second press while it is out asks nothing, so one press
// creates one session and sends one message.
pub fn a_start_carries_the_first_message_once_test() {
  let asked = process.new_subject()
  let model = opened(owner(asked))
  let text = "fix the retry test\nthen update the docs"
  let model = run(model, compose(composer.Started(text, composer.Nothing)))

  assert process.receive(asked, 0)
    == Ok(#(
      creations.Drawn("/src/weft"),
      "fix the retry test",
      creations.Private,
      creations.default_roles,
      text,
    ))

  let model = run(model, compose(composer.Started(text, composer.Nothing)))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "Starting")
}

// The box says what it is for, and an empty message creates the session and asks
// for nothing to be sent.
pub fn the_box_asks_for_a_task_and_an_empty_one_sends_none_test() {
  let asked = process.new_subject()
  let model = opened(owner(asked))
  let html = drawn(model)
  assert string.contains(html, "<textarea")
  assert string.contains(html, "Describe a task or ask a question")
  assert !string.contains(html, "Name this session")

  let _ = run(model, compose(composer.Started("", composer.Nothing)))
  let assert Ok(#(_, name, _, _, prompt)) = process.receive(asked, 0)
  assert name == ""
  assert prompt == ""
}

// The message is untrusted text. It is handed to the daemon as it was typed, to be
// sent as a user message and nothing else, and it is never drawn back by the page:
// not in the box, not in a refusal and not in the sentence.
pub fn a_hostile_message_is_handed_over_and_never_drawn_test() {
  let asked = process.new_subject()
  let hostile = "<img src=x onerror=alert(1)><script>alert(2)</script>"
  let model = opened(owner(asked))
  let model = run(model, compose(composer.Started(hostile, composer.Nothing)))

  let assert Ok(#(_, _, _, _, prompt)) = process.receive(asked, 0)
  assert prompt == hostile

  let model = run(model, home.Created(creations.Declined(creations.NotAFolder)))
  let html = drawn(model)
  assert !string.contains(html, "<img")
  assert !string.contains(html, "<script")
  assert !string.contains(html, "alert(")
}

// A session that was created and kept without its first message is offered, in one
// plain line and a button; the page does not depart until the button is pressed,
// and then departs for the session the daemon kept.
pub fn a_kept_session_without_its_message_is_offered_not_deleted_test() {
  let model = opened(owner(process.new_subject()))
  let model = run(model, compose(composer.Started("hello", composer.Nothing)))
  let model =
    run(model, home.Created(creations.Unsent("/ui/sessions/S?ticket=T")))
  let html = drawn(model)

  assert string.contains(html, "its first message was not sent")
  assert string.contains(html, "Open the session")
  assert !string.contains(html, "Starting")

  // The ticket is the daemon's text: not drawn, and not departed with yet.
  assert !string.contains(html, "/ui/sessions/S")

  let departed = run(model, compose(composer.OpenedUnsent))
  assert string.contains(drawn(departed), "/ui/sessions/S?ticket=T")
}

//// The owner's page and the orchestrators its daemon relays for
//// (protocol-change/094, the placement revamp's slice S2b): the composer's Agent
//// chip, the box's offers in the Code list, a create on a box, and the box's
//// sessions in the sidebar.
////
//// These tests pin that the Agent chip offers only the orchestrators the daemon
//// is configured with and only the ones that answered; that choosing another
//// orchestrator switches the Code list to what it offers and drops the choices
//// that belong to this machine; that a start on a box asks it once, for a place
//// it offered, and that the answer departs for the page of the session it named;
//// that a refused or half-done create says so on the form; and that the sidebar
//// draws a box's sessions, links only the rows it holds, keeps the last rows of a
//// box that stopped answering with a line saying so, and asks a slow box one call
//// at a time. Text from a box is drawn as text, with harmless markup that must
//// come out escaped.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/composer
import web_view/creations
import web_view/home
import web_view/listing
import web_view/orchestrators
import web_view/placements
import web_view/relayed
import web_view/sessions.{type Entry, Entry, Live}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

const key = "abababababababababababababababababababababababababababababababab"

const session = "0198c0de-0000-7000-8000-000000000001"

const other_session = "0198c0de-0000-7000-8000-000000000002"

fn entry(id: String, name: String, workspace: String) -> Entry {
  Entry(
    id:,
    name:,
    workspace:,
    created_at: 100_000,
    residency: Live,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn report(workspaces: List(String)) -> placements.Report {
  placements.Report(
    state: placements.Ready,
    platform: None,
    enforcement: None,
    toolchains: [],
    free_scopes: None,
    workspaces:,
    contradiction: None,
  )
}

// What the box offers: one folder, an executor with one workspace, one profile
// and one model.
fn box_offers() -> orchestrators.Offers {
  orchestrators.Offers(
    folders: ["/srv/app"],
    cards: placements.Cards(
      placements: placements.Placements(
        executors: [placements.Executor("exec", Some(report(["repo"])))],
        pools: [],
      ),
      readiness: placements.Checked,
    ),
    profiles: ["default"],
    models: ["m1"],
  )
}

fn listed(
  id: String,
  name: String,
  activity: relayed.Activity,
) -> orchestrators.Listed {
  orchestrators.Listed(
    session: id,
    name:,
    code: listing.Registered(executor: "exec", workspace: "repo"),
    activity:,
    updated_ms: 1000,
  )
}

type Created =
  Subject(#(String, creations.Place, creations.Roles, String))

type Asked =
  Subject(String)

// What the daemon answers a create with, and what it records of the asks.
type Daemon {
  Daemon(
    founding: orchestrators.Founding,
    created: Created,
    listed: Asked,
    offered: Asked,
  )
}

fn daemon(founding: orchestrators.Founding) -> Daemon {
  Daemon(
    founding:,
    created: process.new_subject(),
    listed: process.new_subject(),
    offered: process.new_subject(),
  )
}

// A box that answers and one that does not.
fn held(daemon: Daemon) -> home.Orchestrators {
  home.Orchestrators(
    key:,
    names: ["box", "gpu"],
    refresh_ms: 5,
    offers: fn(name, deliver) {
      process.send(daemon.offered, name)
      case name {
        "box" -> deliver(orchestrators.Offered(box_offers()))
        _ ->
          deliver(orchestrators.Withheld("the orchestrator is not reachable"))
      }
    },
    sessions: fn(name, deliver) {
      process.send(daemon.listed, name)
      case name {
        "box" ->
          deliver(
            orchestrators.Heard([
              listed(session, "fix retry", relayed.NeedsYou),
              listed(other_session, "<b>x</b> & \"q\"", relayed.Idle),
            ]),
          )
        _ -> deliver(orchestrators.Missed("the orchestrator is not reachable"))
      }
    },
    create: fn(name, place, roles, prompt, deliver) {
      process.send(daemon.created, #(name, place, roles, prompt))
      deliver(daemon.founding)
    },
  )
}

fn owner(orchestrating: option.Option(home.Orchestrators)) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) {
      deliver(home.Listed([entry("A", "web ui", "/src/loom")]))
    },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 7_400_000 },
    activity: fn(_, deliver) { deliver([]) },
    rename: None,
    manage: None,
    create: Some(fn(_, _, _, _, _, _) { Nil }),
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
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self: None,
    visiting: None,
    orchestrators: orchestrating,
    executors: ["local-exec"],
    pools: [],
    machine: "laptop",
    placements: fn(_) { Nil },
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

// The owner's page after its first list read and its first read of the boxes.
fn opened(start: home.Start) -> home.Model {
  let model = run(home.new(start), home.TimerReady(process.new_subject()))
  run(model, home.SideTimerReady(process.new_subject()))
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

fn compose(message: composer.Msg) -> home.Msg {
  home.Composed(message)
}

// The page after the Agent chip was opened, which reads every box's offers.
fn agent_open(model: home.Model) -> home.Model {
  run(model, compose(composer.Toggled(composer.AgentChip)))
}

fn on_box(model: home.Model) -> home.Model {
  run(model, compose(composer.ChoseAgent(composer.Orchestrator("box"))))
}

// The Agent chip lists this daemon and each configured orchestrator, and each row
// says whether it can be chosen: the box that answered is a button, the one that
// did not is text with its reason.
pub fn the_agent_chip_offers_each_configured_orchestrator_test() {
  let record = daemon(orchestrators.Founded(session))
  let model = agent_open(opened(owner(Some(held(record)))))
  let html = drawn(model)

  assert string.contains(html, "aria-label=\"Where the agent runs\"")
  assert string.contains(html, ">laptop</span>")
  assert string.contains(html, ">box</span>")
  assert string.contains(html, ">gpu</span>")

  // The box has two sessions in the sidebar's list: one needs the owner.
  assert string.contains(html, "1 needs you")

  // The one that did not answer says why and cannot be pressed.
  assert string.contains(html, "the orchestrator is not reachable")
  assert string.contains(html, "unavailable")
  assert string.contains(
    html,
    "Switching keeps the workspace choice when the new machine offers it",
  )

  // Opening the chip asked each box once.
  assert process.receive(record.offered, 0) == Ok("box")
  assert process.receive(record.offered, 0) == Ok("gpu")
  assert process.receive(record.offered, 0) == Error(Nil)
}

// A page whose daemon has no orchestrator draws the one row and reads nothing.
pub fn a_page_without_orchestrators_offers_only_this_daemon_test() {
  let model = agent_open(opened(owner(None)))
  let html = drawn(model)

  assert string.contains(html, ">laptop</span>")
  assert !string.contains(html, ">box</span>")
  assert !string.contains(html, "relayed-side")
}

// A row the page did not draw, or one that cannot be chosen yet, changes nothing.
pub fn only_a_machine_that_answered_can_be_chosen_test() {
  let model =
    agent_open(
      opened(owner(Some(held(daemon(orchestrators.Founded(session)))))),
    )

  let gone =
    run(model, compose(composer.ChoseAgent(composer.Orchestrator("gpu"))))
  assert home.composer_state(gone).agent == composer.Here

  let unknown =
    run(model, compose(composer.ChoseAgent(composer.Orchestrator("nowhere"))))
  assert home.composer_state(unknown).agent == composer.Here

  let chosen = on_box(model)
  assert home.composer_state(chosen).agent == composer.Orchestrator("box")
}

// Choosing a box makes its offers the Code list: its folders, its executors and
// their workspaces, no typed path, and a disabled row for this machine's files.
// This machine's folders and recent places are gone.
pub fn choosing_a_box_switches_the_code_offers_test() {
  let model =
    on_box(
      agent_open(
        opened(owner(Some(held(daemon(orchestrators.Founded(session)))))),
      ),
    )
  let model = run(model, compose(composer.Toggled(composer.CodeChip)))
  let html = drawn(model)

  assert string.contains(
    html,
    "Agent</span><span class=\"place-chip-value\">box",
  )
  assert string.contains(html, "On box")
  assert string.contains(html, "/srv/app")
  assert string.contains(html, "exec · repo")
  assert string.contains(html, "box cannot read laptop&#39;s files")
    || string.contains(html, "box cannot read laptop's files")

  // Nothing of this machine is offered as a place.
  assert !string.contains(html, "Choose a folder")
  assert !string.contains(html, "Start again where you worked")

  // The sentence says who relays.
  assert string.contains(html, "This page relays it: approvals come here.")
}

// A choice of this machine's folder does not survive the switch, and a workspace
// of an executor does when the box offers it.
pub fn a_switch_keeps_only_the_choices_the_box_offers_test() {
  let model = opened(owner(Some(held(daemon(orchestrators.Founded(session))))))
  let model =
    run(model, compose(composer.ChoseTarget(composer.Folder("/src/loom"))))
  let model = on_box(agent_open(model))

  // The folder was this machine's, and its path is not the box's.
  assert home.composer_state(model).target == None

  // A workspace named by the box stays chosen when the page returns here only if
  // this machine offers it, and it does not.
  let model =
    run(
      model,
      compose(composer.ChoseTarget(composer.OnExecutor("exec", Some("repo")))),
    )
  let model = run(model, compose(composer.ChoseAgent(composer.Here)))
  assert home.composer_state(model).target == None
}

// A forged target for the box is refused: a typed folder, a folder the box did
// not offer, an executor it did not list.
pub fn the_box_is_offered_nothing_the_page_did_not_draw_test() {
  let model =
    on_box(
      agent_open(
        opened(owner(Some(held(daemon(orchestrators.Founded(session)))))),
      ),
    )

  let typed = run(model, compose(composer.ChoseTarget(composer.TypedFolder)))
  assert home.composer_state(typed).target == None

  let folder =
    run(model, compose(composer.ChoseTarget(composer.Folder("/etc"))))
  assert home.composer_state(folder).target == None

  let executor =
    run(
      model,
      compose(composer.ChoseTarget(composer.OnExecutor("other", Some("repo")))),
    )
  assert home.composer_state(executor).target == None

  let drawn_one =
    run(
      model,
      compose(composer.ChoseTarget(composer.OnExecutor("exec", Some("repo")))),
    )
  assert home.composer_state(drawn_one).target
    == Some(composer.OnExecutor("exec", Some("repo")))
}

// A start on the box asks it once, for the place the Code chip names, the roles
// and the message, and the answer departs for the page of the session it named.
pub fn a_start_on_a_box_creates_there_and_departs_for_its_page_test() {
  let record = daemon(orchestrators.Founded(session))
  let model = on_box(agent_open(opened(owner(Some(held(record))))))
  let model = run(model, compose(composer.ChoseProfile(None)))
  let model =
    run(
      model,
      compose(composer.ChoseTarget(composer.OnExecutor("exec", Some("repo")))),
    )
  let model =
    run(
      model,
      compose(composer.Started("fix the retry test", composer.Nothing)),
    )

  assert process.receive(record.created, 0)
    == Ok(#(
      "box",
      creations.Registered("exec", "repo"),
      creations.default_roles,
      "fix the retry test",
    ))
  assert process.receive(record.created, 0) == Error(Nil)

  // The page departs for the relayed page, whose address it built from its own
  // key, the box's key and the session the daemon named.
  assert string.contains(
    drawn(model),
    "to=\"/ui/p/" <> key <> "/orchestrators/box/sessions/" <> session <> "\"",
  )
}

// With the default target, a box's first folder is the place.
pub fn the_default_place_on_a_box_is_its_first_folder_test() {
  let record = daemon(orchestrators.Founded(session))
  let model = on_box(agent_open(opened(owner(Some(held(record))))))
  let _ = run(model, compose(composer.Started("hello", composer.Nothing)))

  assert process.receive(record.created, 0)
    == Ok(#(
      "box",
      creations.Drawn("/srv/app"),
      creations.Roles(Some("default"), None),
      "hello",
    ))
}

// A box that refused the create puts the form back with the box's words, and a
// create whose first message did not arrive offers the session without making
// another.
pub fn a_refused_or_half_done_create_says_so_on_the_form_test() {
  let refused =
    daemon(orchestrators.Refused(
      "the orchestrator already holds 8 of your sessions (max_sessions)",
    ))
  let model = on_box(agent_open(opened(owner(Some(held(refused))))))
  let model = run(model, compose(composer.Started("go", composer.Nothing)))
  let html = drawn(model)

  assert string.contains(html, "already holds 8 of your sessions")
  assert home.composer_state(model).sending == composer.Ready
  assert !string.contains(html, "orchestrators/box/sessions")

  let half = daemon(orchestrators.Unsent(session))
  let model = on_box(agent_open(opened(owner(Some(held(half))))))
  let model = run(model, compose(composer.Started("go", composer.Nothing)))
  let html = drawn(model)
  assert string.contains(
    html,
    "The session was created, but its first message was not sent.",
  )
  assert !string.contains(html, "to=\"/ui/p/")

  // Opening it departs for the page.
  let model = run(model, compose(composer.OpenedUnsent))
  assert string.contains(
    drawn(model),
    "to=\"/ui/p/" <> key <> "/orchestrators/box/sessions/" <> session <> "\"",
  )
}

// A start while the box's offers are not in hand asks nothing: no list offers the
// place, so there is none to ask for.
pub fn a_start_on_a_silent_box_asks_nothing_test() {
  let record = daemon(orchestrators.Founded(session))
  let model = opened(owner(Some(held(record))))

  // The page believes the agent is the box but never read its offers: it only
  // reaches this state by a message the page did not draw, which is refused.
  let model =
    run(model, compose(composer.ChoseAgent(composer.Orchestrator("box"))))
  assert home.composer_state(model).agent == composer.Here
  let model = run(model, compose(composer.Started("go", composer.Nothing)))

  // This daemon is the agent, so the start goes to the daemon's own creation, not
  // to the box.
  assert process.receive(record.created, 0) == Error(Nil)
  assert home.composer_state(model).agent == composer.Here
}

// The sidebar draws the box's sessions after this daemon's, each tagged with the
// box's name and where it runs, and a row that needs the owner says so. A name
// with markup is text.
pub fn the_sidebar_lists_a_boxs_sessions_test() {
  let html =
    drawn(opened(owner(Some(held(daemon(orchestrators.Founded(session)))))))

  assert string.contains(html, "On box")
  assert string.contains(html, "fix retry")
  assert string.contains(html, "needs you")
  assert string.contains(html, "<span class=\"tag-agent\">box</span>")
  assert string.contains(html, "exec · repo")
  assert string.contains(html, "&lt;b&gt;x&lt;/b&gt;")
  assert !string.contains(html, "<b>x</b>")

  // The box that did not answer has no rows, and says so.
  assert string.contains(html, "On gpu")
  assert string.contains(html, "gpu not reachable")
}

// A press on a row departs for its page only when the page holds that row.
pub fn a_row_press_departs_only_for_a_held_row_test() {
  let model = opened(owner(Some(held(daemon(orchestrators.Founded(session))))))

  let pressed = run(model, home.OpeningRelayed("box", session))
  assert string.contains(
    drawn(pressed),
    "to=\"/ui/p/" <> key <> "/orchestrators/box/sessions/" <> session <> "\"",
  )

  // A session the box never listed, a box that is not held and a page with no
  // orchestrators change nothing.
  let unlisted =
    run(
      model,
      home.OpeningRelayed("box", "0198c0de-0000-7000-8000-0000000000ff"),
    )
  assert !string.contains(drawn(unlisted), "to=\"/ui/p/")
  let unknown = run(model, home.OpeningRelayed("nowhere", session))
  assert !string.contains(drawn(unknown), "to=\"/ui/p/")
  let bare = run(opened(owner(None)), home.OpeningRelayed("box", session))
  assert !string.contains(drawn(bare), "to=\"/ui/p/")
}

// A box that stops answering keeps its last rows, quieter, under a line that says
// how long ago they were read. A box that never answered says it is not reachable
// and has no rows.
pub fn a_box_that_stops_answering_keeps_its_last_rows_test() {
  let model = opened(owner(Some(held(daemon(orchestrators.Founded(session))))))
  let model =
    run(
      model,
      home.SideListed(
        "box",
        orchestrators.Missed("the orchestrator is not reachable"),
      ),
    )
  let html = drawn(model)

  assert string.contains(html, "relayed-side-quiet")
  assert string.contains(html, "box not reachable, seen")
  assert string.contains(html, "fix retry")

  // Hearing from it again clears the line.
  let model =
    run(
      model,
      home.SideListed(
        "box",
        orchestrators.Heard([listed(session, "fix retry", relayed.Working)]),
      ),
    )
  let html = drawn(model)
  assert !string.contains(html, "box not reachable")
  assert string.contains(html, "working")
  assert !string.contains(html, "<b>x</b>")

  // The box that never answered is silent with nothing to show.
  let silent =
    run(
      opened(owner(Some(held(daemon(orchestrators.Founded(session)))))),
      home.SideListed(
        "gpu",
        orchestrators.Missed("the orchestrator is not reachable"),
      ),
    )
  assert string.contains(drawn(silent), "gpu not reachable")
}

// A box with a read out is not asked again at the next tick, and one that
// answered is.
pub fn a_slow_box_is_asked_one_call_at_a_time_test() {
  let record = daemon(orchestrators.Founded(session))
  let slow =
    home.Orchestrators(..held(record), sessions: fn(name, _deliver) {
      process.send(record.listed, name)
    })
  let model = opened(owner(Some(slow)))

  assert both_asked(record.listed) == ["box", "gpu"]

  // Neither answered, so the tick starts neither.
  let model = run(model, home.SideTicked)
  assert process.receive(record.listed, 0) == Error(Nil)

  // One answers, and the next tick asks it and no other.
  let model = run(model, home.SideListed("gpu", orchestrators.Missed("down")))
  let _ = run(model, home.SideTicked)
  assert process.receive(record.listed, 0) == Ok("gpu")
  assert process.receive(record.listed, 0) == Error(Nil)
}

// The two names the daemon was asked about, in name order, since the order of
// the reads in one tick is not part of what is promised.
fn both_asked(asked: Asked) -> List(String) {
  let assert Ok(first) = process.receive(asked, 0) as "one read was started"
  let assert Ok(second) = process.receive(asked, 0) as "two reads were started"

  list.sort([first, second], string.compare)
}

// An offers answer that a newer read overtook is dropped.
pub fn a_late_offers_answer_is_dropped_test() {
  let model =
    agent_open(
      opened(owner(Some(held(daemon(orchestrators.Founded(session)))))),
    )
  let stale =
    run(model, home.OffersAnswered("box", 0, orchestrators.Withheld("old")))

  assert home.machines(stale) == home.machines(model)
}

// Every handler the boxes add is beneath a region the owner's socket admits.
pub fn every_orchestrator_handler_is_beneath_an_admitted_region_test() {
  let model =
    on_box(
      agent_open(
        opened(owner(Some(held(daemon(orchestrators.Founded(session)))))),
      ),
    )
  let model = run(model, compose(composer.Toggled(composer.AgentChip)))
  let keys = handlers(home.view(model))

  let beneath = fn(path) {
    string.starts_with(path, home.table_path <> "\t")
    || string.starts_with(path, home.sidebar_path <> "\t")
    || string.starts_with(path, home.signins_path <> "\t")
    || string.starts_with(path, home.admin_path)
  }
  assert list.all(keys, beneath)

  // The two rows of the sidebar's box section are among the sidebar's handlers.
  assert list.count(keys, string.starts_with(_, home.sidebar_path <> "\t")) >= 2
}

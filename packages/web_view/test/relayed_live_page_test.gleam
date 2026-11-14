//// What a live page of a session on another orchestrator draws and does not
//// (protocol-change/108, `Standing.route`).
////
//// The other orchestrator refuses the owner's controls over the feed, so the
//// page draws none of them and asks for none of what they would read. Its
//// remembered-permissions list offers Forget only on a grant this page approved,
//// one at a time, and a confirm re-checks that choice against the list as it
//// stands. The page is driven as `remembered_page_test` drives a local one.

import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/remembered
import web_view/component
import web_view/invites
import web_view/operator_page
import web_view/remembered as holding

const page = "page-1"

fn relayed_start() -> component.Start(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    standing: component.Standing(
      ..start.standing,
      reader: component.DaemonOwner,
      machine: "box",
      route: component.Relayed(page:),
    ),
  )
}

fn grant(path: String) -> json.JsonValue {
  json.Object([
    #("type", json.String("writable_root")),
    #("path", json.String(path)),
  ])
}

fn by_spawner(principal: String) -> json.JsonValue {
  json.Object([
    #("spawner", json.String("laptop")),
    #("by", json.Object([#("principal", json.String(principal))])),
    #("at_ms", json.Int(1_790_000_000_000)),
  ])
}

fn by_login() -> json.JsonValue {
  json.Object([
    #("by", json.Object([#("principal", json.String("alice"))])),
    #(
      "via",
      json.Object([
        #("kind", json.String("login")),
        #("fingerprint", json.String("9c1e0f2ab3d4e5f6")),
      ]),
    ),
    #("at_ms", json.Int(1_790_000_000_000)),
  ])
}

fn row(path: String, provenance: json.JsonValue) -> json.JsonValue {
  json.Object([#("grant", grant(path)), #("provenance", provenance)])
}

fn board() -> json.JsonValue {
  json.Object([
    #("seq", json.Int(7)),
    #(
      "grants",
      json.Array([
        row("/this-page", by_spawner(page)),
        row("/another-page", by_spawner("page-2")),
        row("/box-owner", by_login()),
      ]),
    ),
    #(
      "actions",
      json.Array([
        json.Object([
          #("id", json.String("act-1")),
          #("seq", json.Int(3)),
          #("tool", json.String("bash")),
          #("provenance", by_spawner(page)),
        ]),
      ]),
    ),
  ])
}

fn answer(request: Int) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(request)
    <> ",\"event\":\"snapshot\",\"body\":{\"mode\":\"permissions\",\"board\":"
    <> json.to_string(board())
    <> "}}",
  )
}

// A relayed page whose lane's reads are answered, the permissions read with the
// board above and every other with a refusal.
fn opened() {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(relayed_start()),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer("operator", []), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
    |> answering(wire, page_fixture.read_rounds)
  model
}

fn answering(model, wire, rounds: Int) {
  let reads =
    list.filter(page_fixture.sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
  case reads, rounds {
    [], _ | _, 0 -> model
    _, _ ->
      page_fixture.run(model, operator_page.update, [
        operator_page.Observed(
          component.Arrived(
            list.map(reads, fn(frame) {
              let id = page_fixture.request_id(frame)
              case string.contains(frame, "\"cmd\":\"permissions\"") {
                True -> answer(id)
                False -> page_fixture.refusal(id)
              }
            }),
          ),
        ),
      ])
      |> answering(wire, rounds - 1)
  }
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

// The owner's controls the other orchestrator refuses are not drawn.
pub fn a_relayed_page_draws_none_of_the_controls_the_box_refuses_test() {
  let html = drawn(opened())
  assert !string.contains(html, "Compact now")
  assert !string.contains(html, "aria-label=\"Evolution\"")
  assert !string.contains(html, "Set goal")
}

// Forget is offered on the one grant this page approved and nowhere else, there
// is no Forget all, and the other rows say where to forget them.
pub fn forget_is_offered_only_on_a_grant_this_page_approved_test() {
  let html = drawn(opened())
  assert list.length(string.split(html, "remembered-forget")) == 2
  assert string.contains(html, "/this-page")
  assert !string.contains(html, "Forget all")
  assert list.length(string.split(html, "Approved on the other machine")) == 4
}

fn armed(forget: remembered.Forget) -> holding.Armed {
  holding.Armed(key: "k", forget:)
}

fn wire_of(path: String) -> json.JsonValue {
  grant(path)
}

// A choice the page did not offer is not armed, and a confirm sends nothing for
// one that is not on the list as it stands.
pub fn a_forget_the_page_did_not_offer_is_not_armed_test() {
  let model = opened()
  let offered =
    armed(remembered.ForgetPermission(wire: wire_of("/this-page"), seq: Some(7)))
  let other =
    armed(remembered.ForgetPermission(
      wire: wire_of("/another-page"),
      seq: Some(7),
    ))
  let owner =
    armed(remembered.ForgetPermission(wire: wire_of("/box-owner"), seq: Some(7)))
  let everything = armed(remembered.ForgetEverything(seq: Some(7)))
  let consent = armed(remembered.ForgetConsent(id: "act-1", seq: 3))

  assert component.ask_forget(model, offered) != model
  assert component.ask_forget(model, other) == model
  assert component.ask_forget(model, owner) == model
  assert component.ask_forget(model, everything) == model
  assert component.ask_forget(model, consent) == model
}

fn placed(label: component.Label) -> String {
  let start = relayed_start()
  component.new(component.Start(..start, label: Some(label)))
  |> operator_page.view
  |> element.to_string
}

// A relayed session is in no list this daemon reads, so the strip's second half
// comes from the label the orchestrator's attach answered, for each of the
// three places a session can run.
pub fn a_relayed_page_says_where_its_commands_run_test() {
  let folder =
    placed(component.Label(
      name: "docs",
      workspace: "/srv/work/proj",
      executor: "",
      pool: "",
    ))
  assert string.contains(folder, "Agent on")
  assert string.contains(folder, "Commands on")
  assert string.contains(folder, "box · …/work/proj")

  let registered =
    placed(component.Label(
      name: "docs",
      workspace: "repo",
      executor: "exec",
      pool: "",
    ))
  assert string.contains(registered, "exec · repo")

  let pooled =
    placed(component.Label(
      name: "docs",
      workspace: "repo",
      executor: "",
      pool: "linux",
    ))
  assert string.contains(pooled, "linux pool · repo")
}

// A page whose orchestrator has not answered has no place in its label, and the
// strip says where the agent runs and no more.
pub fn a_relayed_page_without_a_place_names_no_commands_test() {
  let html =
    placed(component.Label(name: "", workspace: "", executor: "", pool: ""))
  assert string.contains(html, "Agent on")
  assert !string.contains(html, "Commands on")
}

// The daemon cannot mint access to a session it does not hold, so the Session
// tab says where the session is invited to, in place of the bookmark's advice,
// which is about how this page was opened.
pub fn a_relayed_page_says_invitations_are_made_on_its_orchestrator_test() {
  let model = opened()
  assert component.share(model) == invites.Elsewhere(machine: "box")

  let html = drawn(model)
  assert string.contains(
    html,
    "This session runs on box, so invitations are made from its own page there.",
  )
  assert !string.contains(html, "opened from a bookmark")
  assert !string.contains(html, "Run loom ui")
}

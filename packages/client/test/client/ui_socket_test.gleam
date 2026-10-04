//// The page socket starts the component its admitted role calls for, and
//// passes on only the browser messages that component attaches handlers for
//// (protocol-change/051, the operator addendum and the addendum on history
//// paging and on strand focus). An observer's page takes one kind of browser
//// message, a click, at the "Load older" button's fixed path or beneath the
//// agent strip's chip list, and has no composer; an operator's takes a click
//// and a submit and nothing else.

import client/daemon/manager
import client/daemon/root
import client/daemon/ui_relay
import client/daemon/ui_socket
import core/workspace
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import session_view/snapshot
import storage/access
import storage/catalogue
import web_view/component
import web_view/image
import web_view/invites
import web_view/sessions

// A page whose transport never opens: what is under test is which
// component starts and what reaches it, not the session.
fn start() -> component.Start(ui_relay.Relay) {
  component.Start(
    session_id: "A",
    label: None,
    workspace_digest: "",
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    transport: component.Transport(
      connect: fn(_, _) { Nil },
      transmit: ui_relay.transmit,
      shut: ui_relay.shut,
      now: fn() { 0 },
      sessions: fn() { [] },
      open: fn(_) { sessions.Declined(sessions.NotHeld) },
      invite: None,
    ),
  )
}

// The first thing a started page sends its browser is the mount: the whole
// rendered tree.
fn mounted(page: ui_socket.Page) -> String {
  let assert Ok(mount) = process.selector_receive(page.frames, 1000)
    as "the page sends its mount"
  json.to_string(mount)
}

pub fn an_observer_gets_the_observers_page_test() {
  let assert Ok(page) = ui_socket.start_page(ui_socket.Observing, start())
    as "the observer's page starts"
  let tree = mounted(page)
  assert string.contains(tree, "observer-bar")
  assert !string.contains(tree, "composer")
  assert !string.contains(tree, "textarea")

  // A forged submit is dropped by the socket before the component sees it,
  // so nothing is redrawn.
  page.forward(
    "{\"kind\":1,\"path\":\"0\",\"name\":\"submit\",\"event\":{\"detail\":{\"formData\":[[\"draft\",\"hi\"]]}}}",
  )
  assert process.selector_receive(page.frames, 200) == Error(Nil)
  page.shutdown()
}

pub fn an_operator_gets_the_operators_page_test() {
  list.each([ui_socket.Operating, ui_socket.Owning], fn(role) {
    let assert Ok(page) = ui_socket.start_page(role, start())
      as "the operator's page starts"
    let tree = mounted(page)
    assert string.contains(tree, "composer")
    assert !string.contains(tree, "observer-bar")

    // The page's only handlers are the cards' clicks and the composer's
    // submit. No key handler exists, so no keystroke can decide a card.
    assert string.contains(tree, "\"submit\"")
    assert !string.contains(tree, "keydown")
    assert !string.contains(tree, "keyup")
    assert !string.contains(tree, "keypress")
    page.shutdown()
  })
}

// Protocol-change/051, the addendum on history paging: an observer's socket
// admits one event, the "Load older" click at its fixed path, and drops
// every other frame: a submit, a click anywhere else, a forged event name
// at the button's path, a batch, a frame of another kind and a malformed
// one.
pub fn an_observer_socket_accepts_only_the_older_click_test() {
  let path = json.to_string(json.string(component.older_path))
  let at = fn(name) {
    "{\"kind\":1,\"path\":"
    <> path
    <> ",\"name\":\""
    <> name
    <> "\",\"event\":{}}"
  }
  assert ui_socket.observer_accepts(at("click"))
  list.each(
    [
      at("submit"),
      at("keydown"),
      at("clicked"),
      "{\"kind\":1,\"path\":\"0\\t4\\t0\",\"name\":\"submit\",\"event\":{}}",
      "{\"kind\":1,\"path\":\"0\\t3\\t1\",\"name\":\"click\",\"event\":{}}",
      "{\"kind\":1,\"name\":\"click\"}",
      "{\"kind\":3,\"messages\":[" <> at("click") <> "]}",
      "{\"kind\":0,\"name\":\"route\",\"value\":\"/elsewhere\"}",
      "{\"kind\":2,\"name\":\"value\"}",
      "not json",
      "",
    ],
    fn(frame) {
      assert !ui_socket.observer_accepts(frame)
    },
  )
}

// Protocol-change/051, the addendum on strand focus: an observer's socket
// also admits a click beneath the agent strip's chip list, where each handler
// is a chip's button, and nothing else beside that list or the older button.
pub fn an_observer_socket_accepts_a_chip_click_test() {
  let click_at = fn(path, name) {
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(path))
    <> ",\"name\":\""
    <> name
    <> "\",\"event\":{}}"
  }
  let chip = component.strip_path <> "\t2\t1"
  assert ui_socket.observer_accepts(click_at(chip, "click"))
  list.each(
    [
      // The list itself, a sibling of it whose path shares the digits, and
      // the panel's title and its parents.
      click_at(component.strip_path, "click"),
      click_at(component.strip_path <> "0\t2", "click"),
      click_at("0\t3\t1\t1\t0", "click"),
      click_at("0\t3\t0", "click"),
      click_at("0\t3\t1", "click"),
      click_at("0\t3", "click"),

      // Another event at a chip's path.
      click_at(chip, "submit"),
      click_at(chip, "keydown"),
      click_at(chip, "input"),

      // A batch, even of chip clicks, is not admitted.
      "{\"kind\":3,\"messages\":[" <> click_at(chip, "click") <> "]}",
    ],
    fn(frame) {
      assert !ui_socket.observer_accepts(frame)
    },
  )
}

// Protocol-change/051, the addendum on the marker relay: the transcript's dots
// and tags, the breadcrumb's link and a strand view's back link carry a marker
// and no handler, and the socket admits a click at none of them. A click at a
// path in the lane's rows, in the centre before the lane, or in the panel
// after the list is dropped, so a forged click at a marker's place asks for
// nothing, and the cards the shell presses in their place are the only clicks
// that focus a strand.
pub fn an_observer_socket_drops_a_click_on_a_marker_test() {
  let click_at = fn(path) {
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(path))
    <> ",\"name\":\"click\",\"event\":{}}"
  }
  list.each(
    [
      // A dot, and a tag inside a spawn card, under the lane's rows.
      "0\t2\t1\t1\t2.0/0\t0",
      "0\t2\t1\t1\t2.0/0\t1\t0\t0\t1",

      // The breadcrumb's link (its child 4; child 5 is the key hint), before
      // the lane in the centre.
      "0\t2\t0\t4",

      // A strand view's back link, after the list in the Strands pane, and a
      // path in the panes after it.
      "0\t3\t0\t2\t0",
      "0\t3\t1\t3\t0",
      "0\t3\t2\t1",
    ],
    fn(path) {
      assert !ui_socket.observer_accepts(click_at(path))
    },
  )

  // What the shell presses instead is a card, which is admitted.
  assert ui_socket.observer_accepts(click_at(component.strip_path <> "\t3\t0"))
}

pub fn an_operator_socket_accepts_only_its_two_events_test() {
  assert ui_socket.operator_accepts("{\"kind\":1,\"name\":\"click\"}")
  assert ui_socket.operator_accepts("{\"kind\":1,\"name\":\"submit\"}")
  assert ui_socket.operator_accepts(
    "{\"kind\":3,\"messages\":[{\"kind\":1,\"name\":\"click\"},{\"kind\":1,\"name\":\"submit\"}]}",
  )
  list.each(
    [
      "{\"kind\":1,\"name\":\"keydown\"}",
      "{\"kind\":1,\"name\":\"input\"}",
      "{\"kind\":0,\"name\":\"route\",\"value\":\"/elsewhere\"}",
      "{\"kind\":2,\"name\":\"value\"}",
      "{\"kind\":4,\"key\":\"k\"}",
      "{\"kind\":3,\"messages\":[]}",
      "{\"kind\":3,\"messages\":[{\"kind\":1,\"name\":\"click\"},{\"kind\":1,\"name\":\"keydown\"}]}",
      "{\"kind\":1}",
      "not json",
    ],
    fn(frame) {
      assert !ui_socket.operator_accepts(frame)
    },
  )
}

// A click at `path` on the page.
fn click_on(path: String) -> String {
  "{\"kind\":1,\"path\":"
  <> json.to_string(json.string(path))
  <> ",\"name\":\"click\",\"event\":{}}"
}

// Protocol-change/051, the addendum on inviting from the session page: only
// an owner's socket admits a click at or beneath the invitation control's
// path. A member operator's socket drops it, alone or inside a batch, and
// still admits the same click anywhere else, so the sidebar's buttons and the
// approval cards are unaffected.
pub fn only_an_owners_socket_admits_the_invitation_click_test() {
  let at = component.invite_path
  let beneath = at <> "\t1"
  list.each([at, beneath, at <> "\t2\t0"], fn(path) {
    assert ui_socket.owner_accepts(click_on(path))
    assert !ui_socket.operator_accepts(click_on(path))
    assert !ui_socket.observer_accepts(click_on(path))
    assert !ui_socket.operator_accepts(
      "{\"kind\":3,\"messages\":["
      <> click_on(component.sidebar_path <> "\t0")
      <> ","
      <> click_on(path)
      <> "]}",
    )
    assert ui_socket.owner_accepts(
      "{\"kind\":3,\"messages\":["
      <> click_on(component.sidebar_path <> "\t0")
      <> ","
      <> click_on(path)
      <> "]}",
    )
  })

  // Neighbours of the path are not the control: the pane's title, its list, a
  // sibling pane and a path that only begins with the same digits.
  list.each(
    [
      "0\t3\t2\t0",
      "0\t3\t2\t1",
      "0\t3\t1\t2",
      "0\t3\t2\t20",
      component.sidebar_path <> "\t2",
    ],
    fn(path) {
      assert ui_socket.operator_accepts(click_on(path))
    },
  )
}

// The owner's socket takes the same two events and no more: a key, an input
// or a frame of another kind is dropped there too.
pub fn an_owners_socket_takes_no_more_than_the_operators_events_test() {
  assert ui_socket.owner_accepts("{\"kind\":1,\"name\":\"click\"}")
  assert ui_socket.owner_accepts("{\"kind\":1,\"name\":\"submit\"}")
  list.each(
    [
      "{\"kind\":1,\"name\":\"keydown\"}",
      "{\"kind\":1,\"name\":\"input\"}",
      "{\"kind\":3,\"messages\":[]}",
      "{\"kind\":2,\"name\":\"value\"}",
      "not json",
    ],
    fn(frame) {
      assert !ui_socket.owner_accepts(frame)
    },
  )
}

// A forged click at the control's path on a member operator's page is dropped
// before the component sees it, so nothing is redrawn.
pub fn a_member_operators_page_drops_the_invitation_click_test() {
  let assert Ok(page) = ui_socket.start_page(ui_socket.Operating, start())
    as "the member operator's page starts"
  let _ = mounted(page)
  page.forward(
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(component.invite_path <> "\t0"))
    <> ",\"name\":\"click\",\"event\":{}}",
  )
  assert process.selector_receive(page.frames, 200) == Error(Nil)
  page.shutdown()
}

fn view(status: manager.Status) -> manager.View {
  manager.View(
    registration: catalogue.Registration(
      id: "0192-abcd",
      path: "/private/db/secret.sqlite",
      workspace: workspace.LocalBinding("/src/loom"),
      name: "web ui",
      configuration: "config-ref",
      created_at: 1_790_000_000_000,
      request_key: "request-key",
      state: catalogue.Saved,
    ),
    status:,
  )
}

// The sidebar's entry carries what a reader is shown and nothing of the
// registration's path, request key or configuration reference: the entry type
// has no field for them.
pub fn a_listed_entry_names_the_session_and_nothing_private_test() {
  let entry = ui_socket.listed_entry(view(manager.Saved))
  assert entry
    == sessions.Entry(
      id: "0192-abcd",
      name: "web ui",
      workspace: "/src/loom",
      created_at: 1_790_000_000_000,
      residency: sessions.Saved,
    )
  assert !string.contains(string.inspect(entry), "secret.sqlite")
  assert !string.contains(string.inspect(entry), "request-key")
  assert !string.contains(string.inspect(entry), "config-ref")
}

// A session the daemon runs, opens or closes is live; one it holds no process
// for is saved.
pub fn a_running_session_is_live_and_the_rest_are_saved_test() {
  list.each(
    [
      manager.Resident("incarnation"),
      manager.Opening("operation"),
      manager.Stopping("operation"),
    ],
    fn(status) {
      assert ui_socket.listed_entry(view(status)).residency == sessions.Live
    },
  )
  list.each(
    [
      manager.Saved,
      manager.Reserved,
      manager.RecoveryBlocked("proof lost"),
    ],
    fn(status) {
      assert ui_socket.listed_entry(view(status)).residency == sessions.Saved
    },
  )
}

// An observer's page is supplied no list, and the read is never made: a
// stolen observer link does not widen to the principal's project list. An
// operator's page is supplied what the read returns.
pub fn only_an_operators_page_is_listed_sessions_test() {
  let entry =
    sessions.Entry(
      id: "a",
      name: "web ui",
      workspace: "/src/loom",
      created_at: 1,
      residency: sessions.Live,
    )
  let asked = process.new_subject()
  let read = fn() {
    process.send(asked, Nil)
    [entry]
  }
  assert ui_socket.listed_for(ui_socket.Observing, read) == []
  assert process.receive(asked, 0) == Error(Nil)
  assert ui_socket.listed_for(ui_socket.Operating, read) == [entry]
  assert process.receive(asked, 0) == Ok(Nil)
}

// Protocol-change/051, the addendum on switching sessions: the sessions
// sidebar is the frame's second child, so its buttons are at paths beneath
// `component.sidebar_path`. An observer's page has no sidebar, and its socket
// drops a click at any of those paths, at the sidebar's own path and at a path
// that only shares its digits, so a forged click asks for no switch.
pub fn an_observer_socket_drops_a_click_beneath_the_sidebar_test() {
  let click_at = fn(path) {
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(path))
    <> ",\"name\":\"click\",\"event\":{}}"
  }
  list.each(
    [
      component.sidebar_path,
      component.sidebar_path <> "\t1\t1\t0\t0",
      component.sidebar_path <> "\t2\t1\t3\t0",
      component.sidebar_path <> "0",
    ],
    fn(path) {
      assert !ui_socket.observer_accepts(click_at(path))
    },
  )
}

// The operator's socket admits a click at a session button like any other
// click, and only as a click: Lustre dispatches it only to a handler the page
// drew there.
pub fn an_operator_socket_admits_a_session_button_click_test() {
  let at = fn(name) {
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(component.sidebar_path <> "\t1\t1\t0\t0"))
    <> ",\"name\":\""
    <> name
    <> "\",\"event\":{}}"
  }
  assert ui_socket.operator_accepts(at("click"))
  assert !ui_socket.operator_accepts(at("keydown"))
}

// An observer's page asks for no ticket even if a request reached the daemon:
// the third layer refuses without asking, so no ticket is minted. An
// operator's page is given what the daemon decides.
pub fn only_an_operators_page_may_ask_for_a_ticket_test() {
  let asked = process.new_subject()
  let ask = fn() {
    process.send(asked, Nil)
    sessions.Ticketed("/ui/sessions/x?ticket=y")
  }
  assert ui_socket.opened_for(ui_socket.Observing, ask)
    == sessions.Declined(sessions.NotHeld)
  assert process.receive(asked, 0) == Error(Nil)
  assert ui_socket.opened_for(ui_socket.Operating, ask)
    == sessions.Ticketed("/ui/sessions/x?ticket=y")
  assert process.receive(asked, 0) == Ok(Nil)
}

// Protocol-change/051, the addendum on images: each page's socket holds the
// one way its images are read, a question sent to its own component from the
// daemon's side. Both roles' components answer it, and a lane that drew
// nothing answers that it drew nothing, at once and not after the wait.
pub fn both_roles_answer_for_an_image_the_page_never_drew_test() {
  list.each(
    [ui_socket.Observing, ui_socket.Operating, ui_socket.Owning],
    fn(role) {
      let assert Ok(page) = ui_socket.start_page(role, start())
        as "the page starts"
      let _ = mounted(page)
      let before = bootstrap.monotonic_time_ms()
      assert page.images("1.0", 0) == Error(Nil)
      assert page.images("", -1) == Error(Nil)
      assert bootstrap.monotonic_time_ms() - before < 1000
      page.shutdown()
    },
  )
}

// A socket that has ended answers no request, and does not make the asking
// handler wait for a component that is gone.
pub fn a_reader_answers_nothing_once_its_socket_has_ended_test() {
  let started = process.new_subject()
  let owner =
    process.spawn(fn() {
      let assert Ok(page) = ui_socket.start_page(ui_socket.Observing, start())
        as "the page starts"
      let ended = process.new_subject()
      process.send(started, #(page.images, ended))
      let assert Ok(Nil) = process.receive(ended, 5000) as "told to end"
      Nil
    })
  let monitor = process.monitor(owner)
  let assert Ok(#(images, ended)) = process.receive(started, 2000)
    as "the reader and the way to end its owner"
  assert images("1.0", 0) == Error(Nil)
  process.send(ended, Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "the owner ends"
  let before = bootstrap.monotonic_time_ms()
  assert images("1.0", 0) == Error(Nil)
  assert bootstrap.monotonic_time_ms() - before < 500
}

// Protocol-change/051, the addendum on images: an operator's frame holds the
// largest submit the page allows, a full draft with the images `admit` takes
// at their base64 size, and is still under the terminal's limit and the class
// the permit is charged for. An observer's frame limit is unchanged.
pub fn an_operators_frame_holds_a_full_prompt_of_images_test() {
  let encoded = image.max_attached_bytes / 3 * 4 + 4
  let quoting = image.max_attached * 4
  assert encoded + quoting + component.prompt_limit + 4096
    < ui_socket.operator_frame_limit
  assert ui_socket.operator_frame_limit < root.message_limit(root.Operator)
  assert ui_socket.operator_frame_limit == root.message_limit(root.PageOperator)
  assert root.message_limit(root.Observer) == 65_536
}

// The operator class is charged for the peak of one submit of a full frame:
// the frame, the event string, the parsed images, the decoded bytes and the
// re-encoding, five copies. The other classes keep their own charge.
pub fn an_operators_charge_covers_a_submits_peak_test() {
  assert root.charge(root.PageOperator) >= 5 * ui_socket.operator_frame_limit
  assert root.charge(root.PageOperator) == root.operator_peak
  assert root.charge(root.Observer) == 65_536 + 8_388_608
  assert root.charge(root.Operator) == 33_554_432 + 8_388_608
  assert root.charge(root.Control) == 65_536
}

// Layer 4 alone: with a member's principal, an open page and no known address,
// `may_invite` says `NotOwner`. Without its principal check it would fall
// through to the address and say `Unavailable`. Neither the allowance nor the
// manager is reachable from it.
pub fn the_principal_check_refuses_a_member_on_its_own_test() {
  let member =
    access.Principal(
      id: "guest",
      display_name: "Guest",
      kind: access.MemberPrincipal,
    )
  let owner =
    access.Principal(
      id: "o",
      display_name: "Owner",
      kind: access.OwnerPrincipal,
    )
  assert ui_socket.may_invite(fn() { Ok(0) }, member, Error(Nil))
    == Error(invites.NotOwner)
  assert ui_socket.may_invite(fn() { Ok(0) }, owner, Error(Nil))
    == Error(invites.Unavailable)
  assert ui_socket.may_invite(fn() { Ok(0) }, owner, Ok("ws://a"))
    == Ok("ws://a")
  assert ui_socket.may_invite(fn() { Error(Nil) }, owner, Ok("ws://a"))
    == Error(invites.NotOwner)
}

// The capability is handed to an owner's page and to no other.
pub fn only_an_owning_page_is_handed_the_capability_test() {
  let ask = fn(_) { invites.Declined(invites.Unavailable) }
  assert ui_socket.invite_capability(ui_socket.Observing, ask) == None
  assert ui_socket.invite_capability(ui_socket.Operating, ask) == None
  let assert Some(_) = ui_socket.invite_capability(ui_socket.Owning, ask)
}

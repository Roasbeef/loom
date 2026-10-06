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
import client/daemon/ui_sessions
import client/daemon/ui_socket
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import session_view/snapshot
import storage/access
import storage/catalogue
import web_view/admin
import web_view/component
import web_view/home
import web_view/image
import web_view/invites
import web_view/remembered
import web_view/sessions

// A page whose transport never opens: what is under test is which
// component starts and what reaches it, not the session.
fn start() -> component.Start(ui_relay.Relay) {
  component.Start(
    session_id: "A",
    label: None,
    workspace_digest: "",
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    standing: component.unplaced,
    transport: component.Transport(
      connect: fn(_, _) { Nil },
      transmit: ui_relay.transmit,
      shut: ui_relay.shut,
      now: fn() { 0 },
      sessions: fn(deliver) { deliver([]) },
      activity: fn(_, _) { Nil },
      open: fn(_) { sessions.Declined(sessions.NotHeld) },
      resume: fn(_, _) { Nil },
      invite: None,
      home: None,
      rename: None,
      shareable: None,
      worktree: None,
      logins: None,
      manage: None,
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

// Protocol-change/070: an observer's socket admits a click at the divider of a
// settled turn's work, at its exact path, and not at its neighbours: another
// place in the row, a key that is not a work's, a forged number, another event
// at the divider's path, or a batch.
pub fn an_observer_socket_accepts_a_divider_click_test() {
  let click_at = fn(path, name) {
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(path))
    <> ",\"name\":\""
    <> name
    <> "\",\"event\":{}}"
  }
  let divider = "0\t2\t1\t1\twork:12.0\t1\t0\t0"
  assert ui_socket.observer_accepts(click_at(divider, "click"))
  assert ui_socket.observer_accepts(click_at(
    "0\t2\t1\t1\twork:window-start\t1\t0\t0",
    "click",
  ))
  list.each(
    [
      // The row, its body, the work's element and a step beneath it.
      click_at("0\t2\t1\t1\twork:12.0", "click"),
      click_at("0\t2\t1\t1\twork:12.0\t1", "click"),
      click_at("0\t2\t1\t1\twork:12.0\t1\t0", "click"),
      click_at(divider <> "\t0", "click"),
      click_at("0\t2\t1\t1\twork:12.0\t1\t0\t1", "click"),

      // A piece that is not a turn's work, and keys that are not a work's.
      click_at("0\t2\t1\t1\t12.0\t1\t0\t0", "click"),
      click_at("0\t2\t1\t1\tlive\t1\t0\t0", "click"),
      click_at("0\t2\t1\t1\twork:12\t1\t0\t0", "click"),
      click_at("0\t2\t1\t1\twork:-1.0\t1\t0\t0", "click"),
      click_at("0\t2\t1\t1\twork:012.0\t1\t0\t0", "click"),
      click_at("0\t2\t1\t1\twork:12.0.1\t1\t0\t0", "click"),
      click_at("0\t2\t1\t1\twork:\t1\t0\t0", "click"),

      // The lane's other children and the older button's neighbours.
      click_at("0\t2\t1\t0\twork:12.0\t1\t0\t0", "click"),
      click_at("0\t2\t0\t1\twork:12.0\t1\t0\t0", "click"),

      // Another event at the divider's path, and a batch.
      click_at(divider, "submit"),
      click_at(divider, "keydown"),
      "{\"kind\":3,\"messages\":[" <> click_at(divider, "click") <> "]}",
    ],
    fn(frame) {
      assert !ui_socket.observer_accepts(frame)
    },
  )
}

// Protocol-change/065, the second pull request: an observer's socket admits one
// more click, at the "Home" button's exact path, and not its neighbours in the
// top bar, anything beneath it, another event at it, or the path inside a
// batch.
pub fn an_observer_socket_accepts_the_home_click_at_its_exact_path_test() {
  let click_at = fn(path, name) {
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(path))
    <> ",\"name\":\""
    <> name
    <> "\",\"event\":{}}"
  }
  assert ui_socket.observer_accepts(click_at(component.home_path, "click"))
  list.each(
    [
      click_at(component.home_path, "submit"),
      click_at(component.home_path, "keydown"),
      click_at(component.home_path <> "\t0", "click"),
      click_at("0\t0", "click"),
      click_at("0\t0\t0", "click"),
      click_at("0\t0\t2", "click"),
      click_at("0\t0\t11", "click"),
      "{\"kind\":3,\"messages\":["
        <> click_at(component.home_path, "click")
        <> "]}",
    ],
    fn(frame) {
      assert !ui_socket.observer_accepts(frame)
    },
  )
}

// Only a page opened from a home is handed the capability to go home: a page
// a link for one session opened is not, so it draws no button and cannot call.
pub fn only_a_workspace_page_is_handed_the_way_home_test() {
  let ask = fn() { sessions.Declined(sessions.NoHome) }
  assert ui_socket.home_capability(ui_sessions.OneSession, ask) == None
  let assert Some(_) = ui_socket.home_capability(ui_sessions.Workspace, ask)
}

// Protocol-change/065, the second pull request: the home's socket admits a
// click beneath the sessions table's section or the sidebar's column, where a
// running session's row is, and nothing else.
pub fn the_home_socket_admits_only_a_click_on_a_row_test() {
  let click_at = fn(path, name) {
    "{\"kind\":1,\"path\":"
    <> json.to_string(json.string(path))
    <> ",\"name\":\""
    <> name
    <> "\",\"event\":{}}"
  }
  let table_row = home.table_path <> "\t1\t2\t0\t0\t0"
  let sidebar_row = home.sidebar_path <> "\t1\t1\t0\t0"
  assert ui_socket.home_accepts(click_at(table_row, "click"))
  assert ui_socket.home_accepts(click_at(sidebar_row, "click"))
  assert ui_socket.home_accepts(
    "{\"kind\":3,\"messages\":["
    <> click_at(table_row, "click")
    <> ","
    <> click_at(sidebar_row, "click")
    <> "]}",
  )
  list.each(
    [
      // The regions themselves and a sibling that shares their digits.
      click_at(home.table_path, "click"),
      click_at(home.sidebar_path, "click"),
      click_at(home.table_path <> "0\t1", "click"),
      click_at(home.sidebar_path <> "0\t1", "click"),

      // The frame's other children, the top bar's and the centre's others.
      click_at("0\t0\t1", "click"),
      click_at("0\t2\t0", "click"),
      click_at("0\t2\t2", "click"),
      click_at("0\t3", "click"),
      click_at("0", "click"),

      // Another event at a row, or none at all.
      click_at(table_row, "submit"),
      click_at(table_row, "keydown"),
      click_at(sidebar_row, "input"),
      "{\"kind\":1,\"name\":\"click\"}",

      // A batch with one message outside a row, an empty one and other kinds.
      "{\"kind\":3,\"messages\":["
        <> click_at(table_row, "click")
        <> ","
        <> click_at("0\t0\t1", "click")
        <> "]}",
      "{\"kind\":3,\"messages\":[]}",
      "{\"kind\":0,\"name\":\"route\",\"value\":\"/elsewhere\"}",
      "{\"kind\":2,\"name\":\"value\"}",
      "not json",
      "",
    ],
    fn(frame) {
      assert !ui_socket.home_accepts(frame)
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

// The session controls sit beneath their own path in the Session pane, which
// is not the invitation's: a member operator's socket admits a click or a
// submit there, and an observer's admits neither.
pub fn the_session_controls_are_admitted_for_an_operator_not_an_observer_test() {
  let beneath = component.session_controls_path <> "\t1\t0\t0"
  assert ui_socket.operator_accepts(click_on(beneath))
  assert ui_socket.owner_accepts(click_on(beneath))
  assert !ui_socket.observer_accepts(click_on(beneath))
  assert !string.starts_with(
    component.session_controls_path,
    component.invite_path,
  )
}

fn view(status: manager.Status) -> manager.View {
  manager.View(
    registration: catalogue.Registration(
      id: "0192-abcd",
      path: "/private/db/secret.sqlite",
      workspace: "/src/loom",
      name: "web ui",
      configuration: "config-ref",
      created_at: 1_790_000_000_000,
      request_key: "request-key",
      state: catalogue.Saved,
      subtitle: option.None,
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
      subtitle: option.None,
      role: option.None,
      project: None,
    )
  assert !string.contains(string.inspect(entry), "secret.sqlite")
  assert !string.contains(string.inspect(entry), "request-key")
  assert !string.contains(string.inspect(entry), "config-ref")
}

// A session the daemon runs, opens or closes is live; one it holds no process
// for is saved, and one whose creation was never reconciled or whose recovery
// stopped is blocked, which a page may not ask the daemon to resume.
pub fn a_running_session_is_live_and_the_rest_are_saved_or_blocked_test() {
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
  assert ui_socket.listed_entry(view(manager.Saved)).residency == sessions.Saved
  list.each(
    [manager.Reserved, manager.RecoveryBlocked("proof lost")],
    fn(status) {
      assert ui_socket.listed_entry(view(status)).residency == sessions.Blocked
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
      subtitle: option.None,
      role: option.None,
      project: None,
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

// The sidebar's read runs off the page's runtime: `listed_task` returns
// before the read has answered, and the answer arrives through `deliver`
// from the task once the read does. A read that blocks as a registry call
// at its timeout would, here a read that sleeps for a while, holds the
// task and nothing else. An observer's page is answered at once, with no
// read made and no task started.
pub fn the_sidebar_read_runs_off_the_runtime_test() {
  let delivered = process.new_subject()
  let entry =
    sessions.Entry(
      id: "a",
      name: "web ui",
      workspace: "/src/loom",
      created_at: 1,
      residency: sessions.Live,
      subtitle: option.None,
      role: option.None,
      project: option.None,
    )
  let read = fn() {
    process.sleep(300)
    [entry]
  }
  let deliver = fn(entries) { process.send(delivered, entries) }

  // The call returns while the read is still waiting, and the answer lands
  // once the read does.
  ui_socket.listed_task(ui_socket.Operating, read, deliver)
  assert process.receive(delivered, 100) == Error(Nil)
  assert process.receive(delivered, 6000) == Ok([entry])

  // An observer's page: the empty list, now, and the read never runs.
  ui_socket.listed_task(ui_socket.Observing, read, deliver)
  assert process.receive(delivered, 0) == Ok([])
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
  let fresh = ui_sessions.Fresh
  assert ui_socket.invite_capability(ui_socket.Observing, fresh, ask) == None
  assert ui_socket.invite_capability(ui_socket.Operating, fresh, ask) == None
  let assert Some(_) = ui_socket.invite_capability(ui_socket.Owning, fresh, ask)

  // A page a bookmark opened is handed none, whoever its principal is.
  assert ui_socket.invite_capability(ui_socket.Owning, ui_sessions.Resumed, ask)
    == None
}

// Making a session shareable has the invitation control's rule: an owner's page
// is handed it, and a member's page and a read-only page are not.
pub fn only_an_owning_page_is_handed_make_shareable_test() {
  let ask = fn(_deliver) { Nil }
  let fresh = ui_sessions.Fresh
  assert ui_socket.shareable_capability(ui_socket.Observing, fresh, ask) == None
  assert ui_socket.shareable_capability(ui_socket.Operating, fresh, ask) == None
  let assert Some(_) =
    ui_socket.shareable_capability(ui_socket.Owning, fresh, ask)

  // A page a bookmark opened mints no access: an owner's page gets none.
  assert ui_socket.shareable_capability(
      ui_socket.Owning,
      ui_sessions.Resumed,
      ask,
    )
    == None
}

// A page whose transport hands it the capability to go home that
// `home_capability` gives a page of `reach`, and whose `ask` reports each
// press on `asked` before it answers with a ticket. What is under test is the
// daemon's glue, not the component: the reach decides whether the page draws a
// Home button, and the button's press arrives at the asker.
fn going_home(
  reach: ui_sessions.Reach,
  asked: process.Subject(Nil),
) -> component.Start(ui_relay.Relay) {
  let ask = fn() {
    process.send(asked, Nil)
    sessions.Ticketed("/ui/exchange?ticket=home-ticket")
  }
  let start = start()
  component.Start(
    ..start,
    transport: component.Transport(
      ..start.transport,
      home: ui_socket.home_capability(reach, ask),
    ),
  )
}

// The frame a browser sends for a click at `path`.
fn click_at(path: String) -> String {
  "{\"kind\":1,\"path\":"
  <> json.to_string(json.string(path))
  <> ",\"name\":\"click\",\"event\":{}}"
}

// Reads frames until one contains `text`, or the page goes quiet.
fn frames_contain(page: ui_socket.Page, text: String) -> Bool {
  case process.selector_receive(page.frames, 1000) {
    Error(Nil) -> False
    Ok(frame) ->
      case string.contains(json.to_string(frame), text) {
        True -> True
        False -> frames_contain(page, text)
      }
  }
}

// A page opened from a home (`Workspace` reach) draws the Home button, and a
// click at its path reaches the daemon's asker and navigates to its ticket,
// for an observer's and an operator's page alike. A page a link for one
// session opened (`OneSession`) draws no button, and the same frame asks
// nothing.
pub fn a_workspace_page_goes_home_and_a_one_session_page_cannot_test() {
  list.each([ui_socket.Observing, ui_socket.Operating], fn(role) {
    let asked = process.new_subject()
    let assert Ok(page) =
      ui_socket.start_page(role, going_home(ui_sessions.Workspace, asked))
      as "the workspace page starts"
    assert string.contains(mounted(page), "home-link")
    page.forward(click_at(component.home_path))
    assert process.receive(asked, 1000) == Ok(Nil)
    assert frames_contain(page, "home-ticket")
    page.shutdown()

    let asked = process.new_subject()
    let assert Ok(page) =
      ui_socket.start_page(role, going_home(ui_sessions.OneSession, asked))
      as "the one-session page starts"
    assert !string.contains(mounted(page), "home-link")
    page.forward(click_at(component.home_path))
    assert process.receive(asked, 300) == Error(Nil)
    page.shutdown()
  })
}

// A submit at `path` on the page.
fn submit_on(path: String) -> String {
  "{\"kind\":1,\"path\":"
  <> json.to_string(json.string(path))
  <> ",\"name\":\"submit\",\"event\":{}}"
}

// Protocol-change/066: only an owner's socket admits an event at or beneath the
// rename control's path, whether a submit or a click. A member operator's socket
// drops it, alone or inside a batch, and an observer's drops it as it drops
// every submit; the same events anywhere else are unaffected for a member.
pub fn only_an_owners_socket_admits_the_rename_submit_test() {
  let at = component.rename_path
  let beneath = at <> "\trename-0\t0"
  list.each([at, beneath, at <> "\t1"], fn(path) {
    assert ui_socket.owner_accepts(submit_on(path))
    assert ui_socket.owner_accepts(click_on(path))
    assert !ui_socket.operator_accepts(submit_on(path))
    assert !ui_socket.operator_accepts(click_on(path))
    assert !ui_socket.observer_accepts(submit_on(path))
    assert !ui_socket.observer_accepts(click_on(path))
    let batch =
      "{\"kind\":3,\"messages\":["
      <> click_on(component.sidebar_path <> "\t0")
      <> ","
      <> submit_on(path)
      <> "]}"
    assert !ui_socket.operator_accepts(batch)
    assert ui_socket.owner_accepts(batch)
  })

  // Neighbours of the path are not the control: the invitation's, the session
  // controls', the pane's sibling and a path that only begins with the same
  // digits. A member's socket admits a submit at each, as it did before.
  list.each(
    [
      component.session_controls_path,
      component.session_controls_path <> "\t1\t0\t0",
      "0\t3\t2\t3",
      "0\t3\t2\t40",
      "0\t3\t1\t4",
      "0\t2\t4",
    ],
    fn(path) {
      assert ui_socket.operator_accepts(submit_on(path))
    },
  )
}

// The paths the socket pins are exactly these: no admitted path moved when the
// rename control was added after the others.
pub fn the_pinned_event_paths_have_not_moved_test() {
  assert component.strip_path == "0\t3\t0\t1\t0"
  assert component.invite_path == "0\t3\t2\t2"
  assert component.session_controls_path == "0\t3\t2\t3"
  assert component.older_path == "0\t2\t1\t0\t0"
  assert component.sidebar_path == "0\t1"
  assert component.home_path == "0\t0\t1"
  assert home.table_path == "0\t2\t1"
  assert home.sidebar_path == "0\t1"
  assert component.rename_path == "0\t3\t2\t4"

  // The new path is the pane's next child, after the invitation's and the
  // controls', and begins with neither.
  assert !string.starts_with(component.rename_path, component.invite_path)
  assert !string.starts_with(
    component.rename_path,
    component.session_controls_path,
  )
}

// Only an owner's page is handed the capability to rename, so any other page
// draws no control and has nothing to call.
pub fn only_an_owners_page_is_handed_the_capability_to_rename_test() {
  let ask = fn(_name, _deliver) { Nil }
  assert ui_socket.rename_capability(ui_socket.Observing, ask) == None
  assert ui_socket.rename_capability(ui_socket.Operating, ask) == None
  let assert Some(_) = ui_socket.rename_capability(ui_socket.Owning, ask)
}

fn home_principal(kind: access.PrincipalKind) -> access.Principal {
  access.Principal(id: "p", display_name: "P", kind:)
}

// The home's capability to rename is the owner's on a page minted to operate:
// a member's home, an observer-ceiling owner's home and every other combination
// have none, and the socket for each admits the submit only where the
// capability is.
pub fn only_an_owners_operating_home_may_rename_test() {
  let ask = fn(_session, _name, _deliver) { Nil }
  let owner = home_principal(access.OwnerPrincipal)
  let member = home_principal(access.MemberPrincipal)
  let assert Some(_) =
    ui_socket.home_rename_capability(owner, access.Operator, ask)
  assert ui_socket.home_rename_capability(owner, access.Observer, ask) == None
  assert ui_socket.home_rename_capability(member, access.Operator, ask) == None
  assert ui_socket.home_rename_capability(member, access.Observer, ask) == None
}

// The home's socket admits a submit only beneath the sessions list's section,
// where a row's rename form and a workspace's form that creates a session are
// (protocol-change/067 and 065), and only for an owner's home. It admits both
// forms by path alone, as it admits a click, and which form a submit belongs to
// is decided by the component. A member's home
// still admits clicks on a row and drops every submit; the owner's admits a
// submit beneath the list and nowhere else, not the sidebar, not the regions'
// own paths and not a sibling that shares their digits, and it takes no other
// event.
pub fn the_home_socket_admits_a_rename_submit_only_for_an_owner_test() {
  let row = home.table_path <> "\t1\t2\t0\t0\t0"
  let form = home.table_path <> "\t1\t2\t0\t0"
  let sidebar_row = home.sidebar_path <> "\t1\t1\t0\t0"
  let creation_form = home.table_path <> "\t1\t0\t3"
  assert ui_socket.home_owner_accepts(submit_on(form))
  assert ui_socket.home_owner_accepts(submit_on(creation_form))
  assert ui_socket.home_owner_accepts(submit_on(row))
  assert ui_socket.home_owner_accepts(click_on(row))
  assert ui_socket.home_owner_accepts(click_on(sidebar_row))
  assert ui_socket.home_owner_accepts(
    "{\"kind\":3,\"messages\":["
    <> click_on(row)
    <> ","
    <> submit_on(form)
    <> "]}",
  )

  // Not a member's home, whatever path it names.
  assert !ui_socket.home_accepts(submit_on(form))
  assert !ui_socket.home_accepts(submit_on(creation_form))
  assert !ui_socket.home_accepts(submit_on(row))
  assert ui_socket.home_accepts(click_on(row))
  assert !ui_socket.home_accepts(
    "{\"kind\":3,\"messages\":["
    <> click_on(row)
    <> ","
    <> submit_on(form)
    <> "]}",
  )

  // And not an owner's home outside the list.
  list.each(
    [
      submit_on(home.table_path),
      submit_on(home.sidebar_path),
      submit_on(sidebar_row),
      submit_on(home.table_path <> "0\t1"),
      submit_on("0\t0\t1"),
      submit_on("0\t2\t0"),
      submit_on("0\t2\t2"),
      submit_on("0"),
      "{\"kind\":1,\"name\":\"submit\"}",
      "{\"kind\":1,\"path\":\"0\\t2\\t1\\t1\",\"name\":\"keydown\"}",
      "{\"kind\":1,\"path\":\"0\\t2\\t1\\t1\",\"name\":\"input\"}",
      "{\"kind\":3,\"messages\":[]}",
      "{\"kind\":2,\"name\":\"value\"}",
      "not json",
    ],
    fn(frame) {
      assert !ui_socket.home_owner_accepts(frame)
    },
  )
}

// The home's capability to create a session is the owner's on a page minted to
// operate, as the rename capability is, and the two are separate: each is given
// by its own function and neither implies the other.
pub fn only_an_owners_operating_home_may_create_test() {
  let ask = fn(_place, _name, _sharing, _deliver) { Nil }
  let owner = home_principal(access.OwnerPrincipal)
  let member = home_principal(access.MemberPrincipal)
  let assert Some(_) =
    ui_socket.home_create_capability(owner, access.Operator, ask)
  assert ui_socket.home_create_capability(owner, access.Observer, ask) == None
  assert ui_socket.home_create_capability(member, access.Operator, ask) == None
  assert ui_socket.home_create_capability(member, access.Observer, ask) == None
}

// Only the owner's operating home is handed the recent-folders capability.
pub fn only_an_owners_operating_home_is_handed_the_folders_capability_test() {
  let folders = home.Folders(recent: fn(_) { Nil }, forget: fn(_, _) { Nil })
  let owner = home_principal(access.OwnerPrincipal)
  let member = home_principal(access.MemberPrincipal)
  let assert Some(_) =
    ui_socket.home_folders_capability(owner, access.Operator, folders)
  assert ui_socket.home_folders_capability(owner, access.Observer, folders)
    == None
  assert ui_socket.home_folders_capability(member, access.Operator, folders)
    == None
  assert ui_socket.home_folders_capability(member, access.Observer, folders)
    == None
}

// The home's capability to stop, archive and delete is the owner's, on a page
// minted to operate and opened by a fresh `loom ui` exchange, as the admin
// page's is: a member's home, a read-only link, a home a bookmark resumed and a
// page reached for one session have none.
pub fn only_an_owners_fresh_operating_home_may_manage_sessions_test() {
  let ask = fn(_action, _session, _deliver) { Nil }
  let owner = home_principal(access.OwnerPrincipal)
  let member = home_principal(access.MemberPrincipal)
  let home = ui_sessions.Workspace
  let assert Some(_) =
    ui_socket.home_manage_capability(
      owner,
      access.Operator,
      home,
      ui_sessions.Fresh,
      ask,
    )
  assert ui_socket.home_manage_capability(
      owner,
      access.Observer,
      home,
      ui_sessions.Fresh,
      ask,
    )
    == None
  assert ui_socket.home_manage_capability(
      owner,
      access.Operator,
      home,
      ui_sessions.Resumed,
      ask,
    )
    == None
  assert ui_socket.home_manage_capability(
      owner,
      access.Operator,
      ui_sessions.OneSession,
      ui_sessions.Fresh,
      ask,
    )
    == None
  assert ui_socket.home_manage_capability(
      member,
      access.Operator,
      home,
      ui_sessions.Fresh,
      ask,
    )
    == None
  assert ui_socket.home_manage_capability(
      member,
      access.Observer,
      home,
      ui_sessions.Fresh,
      ask,
    )
    == None
}

// A row's Stop, Archive and Delete are clicks beneath the sessions list's own
// path, so no home's socket admits anything new for them: the owner's and a
// member's both admit the click, and the component, which holds the capability
// or does not, is what ignores it. The same buttons beside the sidebar's rows do
// not exist, and a click at a path that only shares the list's digits is dropped.
pub fn the_row_actions_need_no_new_admission_test() {
  let stop = home.table_path <> "\t1\t2\t0\t1\t0"
  let archive = home.table_path <> "\t1\t2\t0\t1\t1"
  let delete = home.table_path <> "\t1\t2\t0\t1\t2"
  let confirm = home.table_path <> "\t1\t2\t0\t0\t1\t0"
  list.each([stop, archive, delete, confirm], fn(path) {
    assert ui_socket.home_accepts(click_on(path))
    assert ui_socket.home_owner_accepts(click_on(path))
    assert ui_socket.home_admin_accepts(click_on(path))
  })
  assert !ui_socket.home_accepts(click_on("0\t2\t1"))
  assert !ui_socket.home_accepts(click_on("0\t2\t10\t1"))
  assert !ui_socket.home_accepts(click_on("0\t0\t1\t0"))
}

// --- the admin page (protocol-change/065, the fifth pull request) -------------

// The home's capability to open the admin page is the owner's, on a page minted
// to operate and opened by a fresh `loom ui` exchange. A member's home, an owner's
// observer-ceiling home and every other combination have none, and no combination
// of the other two capabilities implies it.
pub fn only_an_owners_fresh_operating_home_may_open_the_admin_page_test() {
  let ask = fn(_deliver) { Nil }
  let owner = home_principal(access.OwnerPrincipal)
  let member = home_principal(access.MemberPrincipal)
  let reach = ui_sessions.Workspace
  let assert Some(_) =
    ui_socket.home_admin_capability(
      owner,
      access.Operator,
      reach,
      ui_sessions.Fresh,
      ask,
    )
  assert ui_socket.home_admin_capability(
      owner,
      access.Observer,
      reach,
      ui_sessions.Fresh,
      ask,
    )
    == None
  assert ui_socket.home_admin_capability(
      member,
      access.Operator,
      reach,
      ui_sessions.Fresh,
      ask,
    )
    == None
  assert ui_socket.home_admin_capability(
      member,
      access.Observer,
      reach,
      ui_sessions.Fresh,
      ask,
    )
    == None
}

// A home is fresh when a `loom ui` exchange or a device link opened it, and not
// when the bookmark's resume did (protocol-change/065, the eighth pull request).
// The rule is one function of the reach and the origin, and a page minted for one
// session is no home, so it is not fresh, which also keeps the capability from
// following any other reach. A home the bookmark resumed is handed no Admin
// button, even the owner's, operating.
pub fn the_freshness_of_a_home_is_one_function_test() {
  assert ui_socket.fresh_home(ui_sessions.Workspace, ui_sessions.Fresh)
    == Ok(Nil)
  assert ui_socket.fresh_home(ui_sessions.Workspace, ui_sessions.Resumed)
    == Error(Nil)
  assert ui_socket.fresh_home(ui_sessions.OneSession, ui_sessions.Fresh)
    == Error(Nil)
  assert ui_socket.fresh_home(ui_sessions.OneSession, ui_sessions.Resumed)
    == Error(Nil)
  let ask = fn(_deliver) { Nil }
  let owner = home_principal(access.OwnerPrincipal)
  assert ui_socket.home_admin_capability(
      owner,
      access.Operator,
      ui_sessions.OneSession,
      ui_sessions.Fresh,
      ask,
    )
    == None
  assert ui_socket.home_admin_capability(
      owner,
      access.Operator,
      ui_sessions.Workspace,
      ui_sessions.Resumed,
      ask,
    )
    == None
}

// The home's socket admits the click on the "Admin" button only for a home that
// may open the admin page, at exactly the button's path and for a click alone. A
// plain home and the owner's other socket drop it, and the admin socket keeps
// every other event dropped.
pub fn the_home_socket_admits_the_admin_click_only_for_a_home_that_may_open_it_test() {
  let button = home.admin_path
  let row = home.table_path <> "\t1\t2\t0\t0\t0"
  assert ui_socket.home_admin_accepts(click_on(button))

  // The same home still takes what the owner's home takes, and no more.
  assert ui_socket.home_admin_accepts(click_on(row))
  assert ui_socket.home_admin_accepts(submit_on(home.table_path <> "\t1\t0\t3"))
  assert ui_socket.home_admin_accepts(
    "{\"kind\":3,\"messages\":["
    <> click_on(row)
    <> ","
    <> click_on(button)
    <> "]}",
  )

  // No other home admits it, whatever frame names the path.
  assert !ui_socket.home_accepts(click_on(button))
  assert !ui_socket.home_owner_accepts(click_on(button))
  assert !ui_socket.home_accepts(
    "{\"kind\":3,\"messages\":["
    <> click_on(row)
    <> ","
    <> click_on(button)
    <> "]}",
  )

  // And the admitted path is the button's and nothing near it.
  list.each(
    [
      submit_on(button),
      click_on("0\t0"),
      click_on("0\t0\t4"),
      click_on("0\t0\t5\t0"),
      click_on("0\t0\t50"),
      click_on("0\t0\t6"),
      click_on("0\t0\t2"),
      "{\"kind\":1,\"path\":\"0\\t0\\t5\",\"name\":\"keydown\"}",
      "{\"kind\":1,\"path\":\"0\\t0\\t5\",\"name\":\"input\"}",
      "{\"kind\":1,\"name\":\"click\"}",
      "{\"kind\":3,\"messages\":[]}",
      "not json",
    ],
    fn(frame) {
      assert !ui_socket.home_admin_accepts(frame)
    },
  )
}

// The admin socket admits a click or a submit beneath the page's body, where
// every control is, alone or batched, and drops every other frame: the bar, the
// notice's place, the body's own path, a sibling that shares its digits, a path
// of another page, other events, and any batch with one of them in it.
pub fn the_admin_socket_admits_only_events_beneath_the_pages_body_test() {
  let inside = admin.body_path <> "\t1\t0\t3"
  assert ui_socket.admin_accepts(click_on(inside))
  assert ui_socket.admin_accepts(submit_on(inside))
  assert ui_socket.admin_accepts(click_on(admin.body_path <> "\t0"))
  assert ui_socket.admin_accepts(
    "{\"kind\":3,\"messages\":["
    <> click_on(inside)
    <> ","
    <> submit_on(inside)
    <> "]}",
  )
  list.each(
    [
      click_on(admin.body_path),
      submit_on(admin.body_path),
      click_on(admin.body_path <> "0"),
      click_on("0\t2\t10"),
      click_on("0\t2\t0"),
      click_on("0\t2"),
      click_on("0\t2\t2"),
      click_on("0\t0\t5"),
      click_on("0\t0"),
      click_on("0\t1\t0"),
      click_on("0\t3\t0"),
      click_on(home.sidebar_path <> "\t1\t0"),
      click_on(""),
      "{\"kind\":1,\"name\":\"click\"}",
      "{\"kind\":1,\"path\":\"0\\t2\\t1\\t0\",\"name\":\"keydown\"}",
      "{\"kind\":1,\"path\":\"0\\t2\\t1\\t0\",\"name\":\"input\"}",
      "{\"kind\":1,\"path\":\"0\\t2\\t1\\t0\",\"name\":\"change\"}",
      "{\"kind\":3,\"messages\":[]}",
      "{\"kind\":3,\"messages\":["
        <> click_on(inside)
        <> ","
        <> click_on("0\t0\t5")
        <> "]}",
      "{\"kind\":2,\"name\":\"value\"}",
      "not json",
    ],
    fn(frame) {
      assert !ui_socket.admin_accepts(frame)
    },
  )
}

// The paths the admin page adds are pinned beside the others: the button is the
// bar's last child and the body is the centre's second, and none of the paths
// pinned before moved.
pub fn the_admin_pages_event_paths_are_pinned_test() {
  assert home.admin_path == "0\t0\t5"
  assert admin.body_path == "0\t2\t1"

  // The body is the home's table's place in the centre, and the button is
  // beneath neither the table's region nor the sidebar's, so no earlier
  // admission covers it.
  assert admin.body_path == home.table_path
  assert !string.starts_with(home.admin_path, home.table_path)
  assert !string.starts_with(home.admin_path, home.sidebar_path)
  assert component.home_path == "0\t0\t1"
  assert !ui_socket.home_owner_accepts(click_on(home.admin_path))
}

// The address a person without `loom` opens to claim in a browser is made from
// the command's own address: the same host and port, `http`, and `/ui/claim`. It
// carries no token and no path of the control socket.
pub fn the_browser_claim_address_is_made_from_the_commands_address_test() {
  assert ui_socket.browser_claim_address("ws://127.0.0.1:4000/v2/control")
    == "http://127.0.0.1:4000/ui/claim"
  assert ui_socket.browser_claim_address("ws://[::1]:53599/v2/control")
    == "http://[::1]:53599/ui/claim"
}

// The role a row says comes from the daemon's membership rows and from nothing a
// page sends: it is matched by session identity, a session with no row keeps
// none (the owner's case), and a role is the membership's own.
pub fn a_row_says_the_role_the_membership_holds_test() {
  let entry = ui_socket.listed_entry(view(manager.Saved))
  assert entry.role == None

  let roles = [#("0192-abcd", access.Observer), #("other", access.Operator)]
  assert ui_socket.with_roles([entry], roles)
    == [sessions.Entry(..entry, role: Some(sessions.Observes))]
  assert ui_socket.with_roles([sessions.Entry(..entry, id: "other")], roles)
    == [sessions.Entry(..entry, id: "other", role: Some(sessions.Operates))]

  // A session with no membership row, and the owner's empty answer, leave the
  // row without a role.
  assert ui_socket.with_roles([sessions.Entry(..entry, id: "x")], roles)
    == [sessions.Entry(..entry, id: "x")]
  assert ui_socket.with_roles([entry], []) == [entry]
}

// Protocol-change/065, the tenth pull request: the home's "Your name" form is
// beneath the account panel, so every home's socket admits a submit there, alone
// or in a batch, and only there. The panel's own path, a sibling that shares its
// digits, the table's and the sidebar's paths for a home that may not submit
// there, and every other event stay dropped, so the new admission is one region
// and one event.
pub fn every_home_socket_admits_a_submit_beneath_the_account_panel_test() {
  let form = home.signins_path <> "\t0\t1\t0"
  let batch =
    "{\"kind\":3,\"messages\":["
    <> click_on(home.signins_path <> "\t3\t0\t0")
    <> ","
    <> submit_on(form)
    <> "]}"
  list.each(
    [
      ui_socket.home_accepts,
      ui_socket.home_owner_accepts,
      ui_socket.home_admin_accepts,
    ],
    fn(accepts) {
      assert accepts(submit_on(form))
      assert accepts(submit_on(home.signins_path <> "\t1"))
      assert accepts(batch)
      list.each(
        [
          // The region itself and a sibling that shares its digits.
          submit_on(home.signins_path),
          submit_on(home.signins_path <> "0\t1"),
          submit_on("0\t2\t3"),
          submit_on("0\t2\t2" <> "0"),

          // Another event at the form.
          "{\"kind\":1,\"path\":\"0\\t2\\t2\\t0\\t1\\t0\",\"name\":\"keydown\"}",
          "{\"kind\":1,\"path\":\"0\\t2\\t2\\t0\\t1\\t0\",\"name\":\"input\"}",
          "{\"kind\":1,\"path\":\"0\\t2\\t2\\t0\\t1\\t0\",\"name\":\"change\"}",

          // A batch with one message outside the panel.
          "{\"kind\":3,\"messages\":["
            <> submit_on(form)
            <> ","
            <> submit_on("0\t0\t1\t0")
            <> "]}",
        ],
        fn(frame) {
          assert !accepts(frame)
        },
      )
    },
  )

  // Beneath the table and the sidebar a member's home still admits no submit.
  assert !ui_socket.home_accepts(submit_on(home.table_path <> "\t1\t2\t0\t0"))
  assert !ui_socket.home_accepts(submit_on(home.sidebar_path <> "\t1\t1\t0\t0"))
}

// The capability to rename oneself is the page's ceiling and nothing else: a
// page minted to operate has it whoever its principal is, and a read-only link
// has none.
pub fn only_an_operating_home_may_rename_itself_test() {
  let ask = fn(_name, _deliver) { Nil }
  let assert Some(_) =
    ui_socket.home_rename_self_capability(access.Operator, ask)
  assert ui_socket.home_rename_self_capability(access.Observer, ask) == None
}

// The session page's sidebar asks the activity read only for a page that lists
// sessions. An operator's page runs it, the answer arriving from the task, and
// an observer's, which lists none, asks nothing, so a watcher's link learns
// nothing of the principal's other sessions.
pub fn the_sidebars_activity_read_is_an_operators_alone_test() {
  let answers = process.new_subject()
  let ask = fn(ids) { list.map(ids, fn(id) { #(id, sessions.Working) }) }
  ui_socket.activity_for(ui_socket.Observing, ask, ["a"], fn(rows) {
    process.send(answers, rows)
  })
  assert process.receive(answers, 200) == Error(Nil)
  ui_socket.activity_for(ui_socket.Operating, ask, ["a"], fn(rows) {
    process.send(answers, rows)
  })
  assert process.receive(answers, 2000) == Ok([#("a", sessions.Working)])
}

// Protocol-change/073: a member operator's socket admits the remembered
// permissions' Forget buttons as it admits an approval card's, because anyone
// who may approve may forget. An observer's socket admits none, and its page
// draws none.
pub fn the_remembered_list_is_an_operators_and_never_an_observers_test() {
  let beneath = component.remembered_path <> "\t1\t0\t1\t1\t0"
  assert ui_socket.operator_accepts(click_on(beneath))
  assert ui_socket.owner_accepts(click_on(beneath))
  assert !ui_socket.observer_accepts(click_on(beneath))
  assert !ui_socket.observer_accepts(click_on(component.remembered_path))
}

fn signin(fingerprint: String) -> access.Signin {
  access.Signin(
    fingerprint:,
    issued_at_ms: 0,
    last_resumed_ms: None,
    expires_at_ms: None,
    issued_by: None,
  )
}

// A login is ended only when the registry answered for its principal and the
// principal's active list did not hold it; a principal the page may not read,
// a failed read and a list longer than a page are left out, so the page notes
// only what the daemon could say.
pub fn a_login_is_judged_ended_only_when_the_registry_could_say_so_test() {
  let alice = remembered.Login("alice", "aaaaaaaaaaaaaaaa")
  let gone = remembered.Login("alice", "bbbbbbbbbbbbbbbb")
  let bob = remembered.Login("bob", "cccccccccccccccc")
  let open = fn() { Ok(1) }

  // The page's own principal is read as `None`, another's as `Some`.
  let signins = fn(target) {
    case target {
      None ->
        Ok(access.SigninPage([signin("aaaaaaaaaaaaaaaa")], access.Exhausted))
      Some("bob") -> Error(Nil)
      Some(_) -> Error(Nil)
    }
  }
  assert ui_socket.ended_logins("alice", open, signins, [alice, gone, bob])
    == [gone]

  // A list that ran past one page proves nothing about a login not on it.
  let long = fn(_) {
    Ok(access.SigninPage([signin("aaaaaaaaaaaaaaaa")], access.Remaining))
  }
  assert ui_socket.ended_logins("alice", open, long, [alice, gone]) == []

  // A page that has itself ended judges nothing.
  assert ui_socket.ended_logins("alice", fn() { Error(Nil) }, signins, [gone])
    == []
}

// Only the owner's page, the one that draws the list, is handed the means to
// ask which sign-ins have ended, so a member's or an observer's page holds no
// way to learn who else signed in.
pub fn an_observers_page_is_handed_no_way_to_judge_sign_ins_test() {
  let ask = fn(_logins, _deliver) { Nil }
  assert ui_socket.logins_capability(ui_socket.Observing, ask) == None
  assert ui_socket.logins_capability(ui_socket.Operating, ask) == None
  assert option.is_some(ui_socket.logins_capability(ui_socket.Owning, ask))
}

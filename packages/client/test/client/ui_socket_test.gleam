//// The page socket starts the component its admitted role calls for, and
//// passes on only the browser messages that component attaches handlers for
//// (protocol-change/051, the operator addendum and the addendum on history
//// paging). An observer's page takes one browser message, the "Load older"
//// click at its fixed path, and has no composer; an operator's takes a
//// click and a submit and nothing else.

import client/daemon/ui_relay
import client/daemon/ui_socket
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import session_view/snapshot
import storage/access
import web_view/component

// A page whose transport never opens: what is under test is which
// component starts and what reaches it, not the session.
fn start() -> component.Start(ui_relay.Relay) {
  component.Start(
    session_id: "A",
    label: None,
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    transport: component.Transport(
      connect: fn(_, _) { Nil },
      transmit: ui_relay.transmit,
      shut: ui_relay.shut,
      now: fn() { 0 },
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
  let assert Ok(page) =
    ui_socket.start_page(access.Participant(access.Observer), start())
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
  list.each([access.Participant(access.Operator), access.Owner], fn(authority) {
    let assert Ok(page) = ui_socket.start_page(authority, start())
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

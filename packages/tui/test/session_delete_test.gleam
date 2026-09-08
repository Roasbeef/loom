//// The picker's delete flow, from the key that asks to the row that goes.
////
//// Every test here is pure: the selector answers a key with an action and
//// the terminal decides what to do about it. What is worth pinning down is
//// that no single keystroke deletes anything, that a withdrawn confirmation
//// leaves the page exactly as it was, and that the answer names the identity
//// the question was asked about rather than the highlighted row.

import etui/backend
import etui/keys
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import tui
import tui/connection
import tui/daemon/protocol
import tui/session_selector
import tui/workspace
import weft

fn row(id: String) -> protocol.Session {
  protocol.Session(id, "/work", "Session " <> id, 0, protocol.Saved)
}

fn page() -> session_selector.State {
  session_selector.new(
    protocol.Page(1, [row("first"), row("second")], None),
    "first",
  )
}

pub fn delete_needs_a_confirmation_before_it_is_requested_test() {
  let assert session_selector.Continue(asking) =
    session_selector.update(keys.Char("d"), page())
    as "d opens a question rather than deleting the highlighted row"
  assert asking.prompt == session_selector.ConfirmingDelete("first")
  assert session_selector.update(keys.Char("y"), asking)
    == session_selector.Delete("first")
}

pub fn a_confirmation_names_the_row_it_was_asked_about_test() {
  let assert session_selector.Continue(moved) =
    session_selector.update(keys.Down, page())
    as "the highlight moves to the second row"
  let assert session_selector.Continue(asking) =
    session_selector.update(keys.Char("d"), moved)
    as "the question is asked about the highlighted row"
  assert session_selector.update(keys.Char("y"), asking)
    == session_selector.Delete("second")
}

pub fn any_key_but_y_withdraws_the_question_test() {
  let assert session_selector.Continue(asking) =
    session_selector.update(keys.Char("d"), page())
    as "the question is open"
  list.each([keys.Char("n"), keys.Escape, keys.Enter, keys.Down], fn(key) {
    let assert session_selector.Continue(withdrawn) =
      session_selector.update(key, asking)
      as "no key but y answers an open confirmation"
    assert withdrawn == page()
  })
}

pub fn deleting_the_only_row_leaves_a_selectable_page_test() {
  let single =
    session_selector.new(protocol.Page(1, [row("first")], None), "first")
  let emptied = session_selector.without(single, "first")
  assert emptied.page.sessions == []
  assert emptied.selected == 0
  assert session_selector.update(keys.Char("d"), emptied)
    == session_selector.Continue(emptied)
}

pub fn a_removed_row_leaves_the_rest_of_the_page_alone_test() {
  let remaining = session_selector.without(page(), "first")
  assert remaining.page.sessions == [row("second")]
  assert remaining.page.revision == 1
  assert remaining.prompt == session_selector.Browsing
}

pub fn a_refused_delete_leaves_the_page_the_terminal_already_has_test() {
  // The terminal drops a row only on the daemon's confirmation, so a refusal
  // has nothing to apply here: the state the picker keeps after asking is the
  // state it had before, minus the open question.
  let assert session_selector.Continue(asking) =
    session_selector.update(keys.Char("d"), page())
    as "the question is open"
  let assert session_selector.Delete(id) =
    session_selector.update(keys.Char("y"), asking)
    as "the confirmation is answered"
  assert id == "first"
  assert session_selector.without(page(), "absent") == page()
}

// The tests above stop at the selector's own answer. These two carry that
// answer through `tui.update`, which is where the key actually decides
// whether a control job starts.

fn picker(model: tui.Model) -> tui.Model {
  tui.Model(..model, overlay: tui.DaemonSelector(page()))
}

fn blank() -> tui.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("test", None))
}

pub fn a_confirmed_delete_reaches_the_control_job_test() {
  // `d` only opens the question, so nothing about the model's control slot
  // may move on that key alone.
  let asking = tui.update(backend.KeyPress("d"), picker(blank()))
  assert asking.control_request == None
  let assert tui.DaemonSelector(open) = asking.overlay
    as "the picker stays on screen while the question is open"
  assert open.prompt == session_selector.ConfirmingDelete("first")

  // `y` is what reaches `begin_delete`. This model has no daemon host, so
  // the job cannot be started and the refusal is the proof the key arrived:
  // the selector alone has no way to write that notice.
  let answered = tui.update(backend.KeyPress("y"), asking)
  assert answered.notice == "daemon control is disconnected"
  assert answered.control_request == None
}

pub fn a_delete_is_refused_while_a_page_load_is_in_flight_test() {
  // The picker owns one control job slot, and paging holds it first. A
  // forged request stands in for the page load: what matters to
  // `begin_delete` is that the slot is taken, not what took it.
  let replies = process.new_subject()
  let loading =
    tui.Model(
      ..picker(blank()),
      control_request: Some(tui.ControlRequest(
        weft.cancel_signal(),
        replies,
        None,
      )),
    )
  let asking = tui.update(backend.KeyPress("d"), loading)
  let refused = tui.update(backend.KeyPress("y"), asking)

  // The in-flight job keeps the slot it already had, so its reply subject is
  // still the one the frame loop selects on.
  let assert Some(tui.ControlRequest(replies: kept, ..)) =
    refused.control_request
    as "the page load still owns the control slot"
  assert kept == replies
  assert refused.notice == "a catalogue request is already running"

  // A refusal removes no row: only the daemon's confirmation drops one, and
  // none was ever asked for. The question stays open rather than being
  // withdrawn, so answering again once the page load lands costs one key
  // instead of reopening it against a row that may have moved.
  let assert tui.DaemonSelector(shown) = refused.overlay
    as "the picker survives the refusal"
  assert shown.page == page().page
  assert shown.selected == page().selected
  assert shown.prompt == session_selector.ConfirmingDelete("first")
}

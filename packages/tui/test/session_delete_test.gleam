//// The picker's delete flow, from the key that asks to the row that goes.
////
//// Every test here is pure: the selector answers a key with an action and
//// the terminal decides what to do about it. What is worth pinning down is
//// that no single keystroke deletes anything, that a withdrawn confirmation
//// leaves the page exactly as it was, and that the answer names the identity
//// the question was asked about rather than the highlighted row.

import etui/keys
import gleam/list
import gleam/option.{None}
import tui/daemon/protocol
import tui/session_selector

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

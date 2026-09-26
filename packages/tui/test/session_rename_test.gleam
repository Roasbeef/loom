import etui/backend
import etui/widgets/textarea
import gleam/erlang/process
import gleam/option.{None, Some}
import tui
import tui/connection
import tui/daemon/protocol
import tui/model as tui_model
import tui/session_control
import tui/session_selector
import tui/workspace
import weft

pub fn rename_without_attachment_reports_no_session_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let model =
    tui_model.Model(
      ..model,
      session: "",
      input: textarea.state_from_string("/rename review auth"),
    )
  let after = tui.update(backend.KeyPress("enter"), model)
  assert after.control_request == None
  assert after.notice == "no session is attached"
}

pub fn completed_rename_page_refresh_preserves_selected_identity_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let replies = process.new_subject()
  let row =
    protocol.Session("selected", "/work/loom", "review auth", 1, protocol.Saved)
  let page = protocol.Page(9, [row], None)
  let pending =
    tui_model.Model(
      ..model,
      session: row.session_id,
      control_request: Some(tui_model.ControlRequest(
        weft.cancel_signal(),
        replies,
        None,
      )),
    )
  let received =
    session_control.accept_control_event(
      pending,
      tui_model.ControlEvent(
        replies,
        weft.PulledOutcome(weft.Completed(
          0,
          tui_model.PageLoaded(page, row.session_id, session_selector.Active),
        )),
      ),
    )
  let after =
    session_control.accept_control_event(
      received,
      tui_model.ControlEvent(replies, weft.AllDelivered),
    )
  let assert tui_model.DaemonSelector(selector) = after.overlay
    as "the refreshed page is rendered only after the worker drains"
  assert selector.page == page
  assert selector.current == row.session_id
  assert selector.selected == 0
  assert after.session == row.session_id
  assert after.control_request == None
}

// Left from an empty composer asks for the session picker, as `/sessions`
// does. Without daemon control that request is refused in the notice, which
// is the witness that Left reached the picker's path rather than the cursor.
pub fn left_from_an_empty_composer_opens_sessions_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let after = tui.update(backend.KeyPress("left"), model)
  assert after.notice == "daemon control is unavailable; reconnect explicitly"
  assert textarea.value(after.input) == ""
}

// A draft keeps Left as a cursor key, so browsing text never opens the
// picker over it.
pub fn left_inside_a_draft_moves_the_cursor_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let model =
    tui_model.Model(..model, input: textarea.state_from_string("draft"))
  let after = tui.update(backend.KeyPress("left"), model)
  assert after.notice == model.notice
  assert after.overlay == tui_model.NoOverlay
  assert textarea.value(after.input) == "draft"
  assert after.input != model.input
}

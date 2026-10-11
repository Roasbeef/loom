import etui/backend
import etui/widgets/textarea
import gleam/option.{None, Some}
import session_view/shared_set
import tui
import tui/connection
import tui/daemon/protocol
import tui/job
import tui/model as tui_model
import tui/runtime
import tui/session_control
import tui/session_selector
import tui/view_set
import tui/workspace
import weft

pub fn rename_without_attachment_reports_no_session_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let model =
    tui_model.Model(
      shared: shared_set.session(model.shared, ""),
      view: view_set.input(
        model.view,
        textarea.state_from_string("/rename review auth"),
      ),
    )
  let after = tui.update(backend.KeyPress("enter"), model)
  assert after.view.control_request == None
  assert after.shared.notice == "no session is attached"
}

pub fn completed_rename_page_refresh_preserves_selected_identity_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let row =
    protocol.Session(
      "selected",
      "/work/loom",
      "review auth",
      1,
      protocol.Saved,
      option.None,
      option.None,
    )
  let page = protocol.Page(9, [row], None)
  let #(model, key) = tui_model.allocate_job(model)
  let pending =
    tui_model.Model(
      shared: shared_set.session(model.shared, row.session_id),
      view: view_set.control_request(
        model.view,
        Some(tui_model.ControlRequest(job.awaiting(key), None)),
      ),
    )

  // Both replies are admitted before either is taken, as when the runtime
  // receives the relay's two messages together; the drain takes one each.
  let held =
    pending
    |> runtime.hold(job.ControlArrived(
      key,
      weft.PulledOutcome(weft.Completed(
        0,
        job.PageLoaded(page, row.session_id, session_selector.Active),
      )),
    ))
    |> runtime.hold(job.ControlArrived(key, weft.AllDelivered))
  let received = session_control.drain_control(held)
  assert received.view.overlay == pending.view.overlay
    as "the page waits for the worker to drain"
  let after = session_control.drain_control(received)
  let assert tui_model.DaemonSelector(selector) = after.view.overlay
    as "the refreshed page is rendered only after the worker drains"
  assert selector.page == page
  assert selector.current == row.session_id
  assert selector.selected == 0
  assert after.shared.session == row.session_id
  assert after.view.control_request == None
}

// Left from an empty composer asks for the session picker, as `/sessions`
// does. Without daemon control that request is refused in the notice, which
// is the witness that Left reached the picker's path rather than the cursor.
pub fn left_from_an_empty_composer_opens_sessions_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let after = tui.update(backend.KeyPress("left"), model)
  assert after.shared.notice
    == "daemon control is unavailable; reconnect explicitly"
  assert textarea.value(after.view.input) == ""
}

// A draft keeps Left as a cursor key, so browsing text never opens the
// picker over it.
pub fn left_inside_a_draft_moves_the_cursor_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let model =
    tui_model.Model(
      ..model,
      view: view_set.input(model.view, textarea.state_from_string("draft")),
    )
  let after = tui.update(backend.KeyPress("left"), model)
  assert after.shared.notice == model.shared.notice
  assert after.view.overlay == tui_model.NoOverlay
  assert textarea.value(after.view.input) == "draft"
  assert after.view.input != model.view.input
}

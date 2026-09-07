import etui/backend
import etui/widgets/textarea
import gleam/erlang/process
import gleam/option.{None, Some}
import tui
import tui/connection
import tui/daemon/protocol
import tui/workspace
import weft

pub fn rename_without_attachment_reports_no_session_test() {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("/work/loom", None))
  let model =
    tui.Model(
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
    tui.Model(
      ..model,
      session: row.session_id,
      control_request: Some(tui.ControlRequest(
        weft.cancel_signal(),
        replies,
        None,
      )),
    )
  let received =
    tui.accept_control_event(
      pending,
      tui.ControlEvent(
        replies,
        weft.PulledOutcome(weft.Completed(
          0,
          tui.PageLoaded(page, row.session_id),
        )),
      ),
    )
  let after =
    tui.accept_control_event(
      received,
      tui.ControlEvent(replies, weft.AllDelivered),
    )
  let assert tui.DaemonSelector(selector) = after.overlay
    as "the refreshed page is rendered only after the worker drains"
  assert selector.page == page
  assert selector.current == row.session_id
  assert selector.selected == 0
  assert after.session == row.session_id
  assert after.control_request == None
}

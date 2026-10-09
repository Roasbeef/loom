//// Catalogue names are presentation metadata bound to a stable identity.
//// Editing neither opens a session nor changes a name before acknowledgement.

import etui/backend
import etui/keys
import etui/widgets/textarea as text_area
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/model as session_model
import session_view/shared_set
import tui
import tui/buffered
import tui/connection
import tui/daemon/protocol
import tui/frame
import tui/job
import tui/model as tui_model
import tui/runtime
import tui/session_control
import tui/session_selector
import tui/view_set
import tui/virtual_backend
import tui/workspace
import weft

fn row(id: String, name: String) -> protocol.Session {
  protocol.Session(
    id,
    "/work",
    name,
    0,
    protocol.Saved,
    option.None,
    option.None,
  )
}

fn picker() -> session_selector.State {
  session_selector.new(
    protocol.Page(1, [row("a", "Original"), row("b", "Second")], None),
    "a",
  )
}

pub fn rename_edits_the_original_identity_until_explicit_commit_test() {
  let assert session_selector.Continue(editing) =
    session_selector.update(keys.Char("r"), picker())
    as "r starts editing without a daemon mutation"
  let assert session_selector.Continue(cleared) =
    session_selector.update(keys.Ctrl("u"), editing)
    as "the existing title can be replaced"
  assert session_selector.update(keys.Enter, cleared)
    == session_selector.Continue(cleared)

  let assert session_selector.Continue(typed) =
    session_selector.update(keys.Char("Renamed"), cleared)
    as "typing only changes the draft"
  assert session_selector.update(keys.Down, typed)
    == session_selector.Continue(typed)
  assert session_selector.update(keys.Enter, typed)
    == session_selector.Rename("a", "Renamed")
  assert session_selector.update(keys.Escape, typed)
    == session_selector.Continue(picker())
}

pub fn rename_respects_utf8_byte_limit_and_grapheme_backspace_test() {
  let full =
    session_selector.State(
      ..picker(),
      prompt: session_selector.Renaming("a", string.repeat("é", 128)),
    )
  assert session_selector.update(keys.Char("x"), full)
    == session_selector.Continue(full)
  let assert session_selector.Continue(shorter) =
    session_selector.update(keys.Backspace, full)
    as "backspace removes one displayed character"
  assert shorter.prompt
    == session_selector.Renaming("a", string.repeat("é", 127))
}

fn blank() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn acknowledge(
  model: tui_model.Model,
  renamed: protocol.Session,
) -> tui_model.Model {
  let #(model, key) = tui_model.allocate_job(model)
  let waiting =
    tui_model.Model(
      ..model,
      view: view_set.control_request(
        model.view,
        Some(tui_model.ControlRequest(
          job.awaiting(key),
          Some(Ok(job.SessionRenamed(renamed))),
        )),
      ),
    )
  runtime.hold(waiting, job.ControlArrived(key, weft.AllDelivered))
  |> session_control.drain_control
}

pub fn acknowledged_rename_updates_header_and_picker_without_switching_test() {
  let model = {
    let base = blank()
    tui_model.Model(
      shared: base.shared
        |> shared_set.session("a")
        |> shared_set.session_label(Some(#("a", "Original"))),
      view: view_set.overlay(base.view, tui_model.DaemonSelector(picker())),
    )
  }
  let renamed = acknowledge(model, row("a", "Readable title"))
  assert renamed.shared.session == "a"
  assert renamed.shared.session_label == Some(#("a", "Readable title"))
  let assert tui_model.DaemonSelector(selector) = renamed.view.overlay
    as "acknowledgement preserves the picker"
  assert selector.selected == 0
  assert selector.page.sessions
    == [row("a", "Readable title"), row("b", "Second")]
  assert selector.prompt == session_selector.Browsing
  assert string.contains(
    header(
      tui_model.Model(
        ..renamed,
        view: view_set.overlay(renamed.view, tui_model.NoOverlay),
      ),
    ),
    "Readable title",
  )
}

pub fn renaming_another_session_keeps_the_attached_title_test() {
  let model = {
    let base = blank()
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.session("a")
        |> shared_set.session_label(Some(#("a", "Current"))),
    )
  }
  let renamed = acknowledge(model, row("b", "Other"))
  assert renamed.shared.session_label == model.shared.session_label
  assert renamed.shared.session == "a"
  assert string.contains(header(renamed), "Current")
  assert !string.contains(header(renamed), "Other")
}

pub fn a_title_cannot_follow_a_legacy_identity_switch_test() {
  let model = {
    let base = blank()
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.session("new-identity")
        |> shared_set.session_label(Some(#("old-identity", "Old title"))),
    )
  }
  assert string.contains(header(model), "new-identity")
  assert !string.contains(header(model), "Old title")
}

fn header(model: tui_model.Model) -> String {
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 100, height: 12),
      [],
      buffered.sender(model.shared.inbox),
    )
  let assert Ok(run) =
    tui.run_script(
      tui_model.Model(
        ..model,
        shared: shared_set.peer(model.shared, session_model.Replaying),
      ),
      script,
    )
    as "the virtual terminal starts"
  let assert Ok(last) = list.last(run.frames)
    as "the terminal renders the header"
  let assert Ok(first) =
    list.first(string.split(frame.buffer_to_text(last), "\n"))
    as "the first row is the session header"
  first
}

pub fn paste_is_owned_by_the_rename_editor_not_the_chat_draft_test() {
  let editing =
    session_selector.State(
      ..picker(),
      prompt: session_selector.Renaming("a", ""),
    )
  let model = {
    let base = blank()
    tui_model.Model(
      ..base,
      view: view_set.overlay(base.view, tui_model.DaemonSelector(editing)),
    )
  }
  let pasted = tui.update(backend.Paste("Pasted title"), model)
  let assert tui_model.DaemonSelector(selector) = pasted.view.overlay
    as "paste stays in the rename editor"
  assert selector.prompt == session_selector.Renaming("a", "Pasted title")
  assert text_area.value(pasted.view.input) == text_area.value(model.view.input)
  assert pasted.view.control_request == None

  let oversized = tui.update(backend.Paste(string.repeat("x", 257)), pasted)
  let assert tui_model.DaemonSelector(unchanged) = oversized.view.overlay
    as "oversized paste preserves the draft"
  assert unchanged.prompt == selector.prompt
  assert text_area.value(oversized.view.input)
    == text_area.value(model.view.input)
}

//// Composer paste inserts at the current editor cursor. Large source and
//// image attachments retain their existing attachment semantics.

import etui/backend
import etui/widgets/textarea
import gleam/option.{None}
import gleam/string
import session_view/composer
import session_view/pasted_image
import session_view/shared_set
import tui
import tui/connection
import tui/model as tui_model
import tui/view_set
import tui/workspace

fn model(draft: String) -> tui_model.Model {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui_model.Model(
    ..base,
    view: base.view
      |> view_set.input(textarea.state_from_string(draft))
      |> view_set.history_draft(draft),
  )
}

fn image() -> composer.Attachment {
  composer.ImageAttachment(pasted_image.Image(
    local_path: "/tmp/preview.png",
    filename: "preview.png",
    mime_type: "image/png",
    byte_size: 1,
    data: "YQ==",
  ))
}

pub fn inline_paste_inserts_without_replacing_a_draft_test() {
  let cursor =
    textarea.state_from_string("beforeafter")
    |> textarea.move_cursor_left
    |> textarea.move_cursor_left
    |> textarea.move_cursor_left
    |> textarea.move_cursor_left
    |> textarea.move_cursor_left
  let pasted =
    tui.update(backend.Paste(" middle "), {
      let base = model("")
      tui_model.Model(..base, view: view_set.input(base.view, cursor))
    })
  assert textarea.value(pasted.view.input) == "before middle after"
  assert pasted.view.history_draft == "before middle after"
  assert pasted.view.input.cursor_y == 0
  assert pasted.view.input.cursor_x == 14
}

pub fn multiline_paste_keeps_the_suffix_and_existing_image_attachment_test() {
  let cursor =
    textarea.state_from_string("first\nlast") |> textarea.move_to_line_start
  let initial = {
    let base = model("")
    tui_model.Model(
      shared: shared_set.attachments(base.shared, [image()]),
      view: view_set.input(base.view, cursor),
    )
  }
  let pasted = tui.update(backend.Paste("middle\n"), initial)
  assert textarea.value(pasted.view.input) == "first\nmiddle\nlast"
  assert pasted.view.history_draft == "first\nmiddle\nlast"
  assert pasted.view.input.cursor_y == 2
  assert pasted.view.input.cursor_x == 0
  assert pasted.shared.attachments == initial.shared.attachments
}

pub fn compact_paste_keeps_the_draft_and_existing_attachments_test() {
  let source = string.repeat("x ", 1000)
  let initial = {
    let base = model("review this")
    tui_model.Model(
      ..base,
      shared: shared_set.attachments(base.shared, [image()]),
    )
  }
  let pasted = tui.update(backend.Paste(source), initial)
  assert textarea.value(pasted.view.input) == "review this"
  assert pasted.shared.attachments
    == [
      image(),
      composer.Attachment(source, 500),
    ]
  assert composer.expand(
      textarea.value(pasted.view.input),
      pasted.shared.attachments,
    )
    == "review this\n\n" <> source
}

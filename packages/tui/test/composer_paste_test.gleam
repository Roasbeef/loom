//// Composer paste inserts at the current editor cursor. Large source and
//// image attachments retain their existing attachment semantics.

import etui/backend
import etui/widgets/textarea
import gleam/option.{None}
import gleam/string
import tui
import tui/composer
import tui/connection
import tui/image_drop
import tui/workspace

fn model(draft: String) -> tui.Model {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui.Model(
    ..base,
    input: textarea.state_from_string(draft),
    history_draft: draft,
  )
}

fn image() -> composer.Attachment {
  composer.ImageAttachment(image_drop.Image(
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
    tui.update(backend.Paste(" middle "), tui.Model(..model(""), input: cursor))
  assert textarea.value(pasted.input) == "before middle after"
  assert pasted.history_draft == "before middle after"
  assert pasted.input.cursor_y == 0
  assert pasted.input.cursor_x == 14
}

pub fn multiline_paste_keeps_the_suffix_and_existing_image_attachment_test() {
  let cursor =
    textarea.state_from_string("first\nlast") |> textarea.move_to_line_start
  let initial = tui.Model(..model(""), input: cursor, attachments: [image()])
  let pasted = tui.update(backend.Paste("middle\n"), initial)
  assert textarea.value(pasted.input) == "first\nmiddle\nlast"
  assert pasted.history_draft == "first\nmiddle\nlast"
  assert pasted.input.cursor_y == 2
  assert pasted.input.cursor_x == 0
  assert pasted.attachments == initial.attachments
}

pub fn compact_paste_keeps_the_draft_and_existing_attachments_test() {
  let source = string.repeat("x ", 1000)
  let initial = tui.Model(..model("review this"), attachments: [image()])
  let pasted = tui.update(backend.Paste(source), initial)
  assert textarea.value(pasted.input) == "review this"
  assert pasted.attachments
    == [
      image(),
      composer.Attachment(source, 500),
    ]
  assert composer.expand(textarea.value(pasted.input), pasted.attachments)
    == "review this\n\n" <> source
}

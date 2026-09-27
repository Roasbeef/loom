//// The step reads no file (ADR-013, phase 2 S6).
////
//// A pasted image path is read by `runtime.read_paste` before the step, and
//// the step attaches what that read found. These tests pin both halves: the
//// step alone leaves a pasted path as text even when the path names an
//// image on disk, and a read taken before the step attaches its image even
//// after the file is gone. The behaviour through `tui.update` is unchanged:
//// the image attaches in the step that handled the paste, and a refused
//// image reports the same error it did when the step read the file itself.

import etui/backend
import etui/widgets/textarea
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import simplifile
import tui
import tui/composer
import tui/connection
import tui/image_drop
import tui/model as tui_model
import tui/runtime
import tui/workspace

// The smallest byte string `image_drop.media_type` recognises as a PNG.
const png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01>>

fn model() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn write(path: String, bytes: BitArray) -> Nil {
  let assert Ok(Nil) = simplifile.write_bits(to: path, bits: bytes)
    as "the fixture file is written under the package build directory"
  Nil
}

fn image_names(model: tui_model.Model) -> List(String) {
  list.filter_map(model.attachments, fn(attachment) {
    case attachment {
      composer.ImageAttachment(image_drop.Image(filename:, ..)) -> Ok(filename)
      composer.Attachment(..) -> Error(Nil)
    }
  })
}

pub fn a_pasted_image_attaches_in_the_step_that_handled_the_paste_test() {
  let path = "build/s6-pasted.png"
  write(path, png)
  let pasted = tui.update(backend.Paste(path), model())
  let _ = simplifile.delete(path)

  assert image_names(pasted) == ["s6-pasted.png"]
  assert textarea.value(pasted.input) == ""
}

pub fn the_step_alone_leaves_a_pasted_image_path_as_text_test() {
  let path = "build/s6-unread.png"
  write(path, png)
  let #(stepped, _effects) = tui.step(backend.Paste(path), model())
  let _ = simplifile.delete(path)

  assert image_names(stepped) == []
  assert textarea.value(stepped.input) == path
}

// The read before the step is the only read: the file is deleted between
// `read_paste` and the step, and the image still attaches from what the
// read found. A step that read the file itself would find nothing there.
pub fn the_step_attaches_what_the_read_before_it_found_test() {
  let path = "build/s6-read-first.png"
  write(path, png)
  let read = runtime.read_paste(backend.Paste(path), model())
  let assert Ok(Nil) = simplifile.delete(path)
  let #(stepped, _effects) = tui.step(backend.Paste(path), read)

  assert image_names(stepped) == ["s6-read-first.png"]
  assert textarea.value(stepped.input) == ""
}

// A read belongs to the paste text it was taken for. A step for another
// paste treats it as no read at all.
pub fn a_read_for_another_paste_is_not_attached_test() {
  let path = "build/s6-other.png"
  write(path, png)
  let read = runtime.read_paste(backend.Paste(path), model())
  let _ = simplifile.delete(path)
  let #(stepped, _effects) = tui.step(backend.Paste("later words"), read)

  assert image_names(stepped) == []
  assert textarea.value(stepped.input) == "later words"
}

pub fn an_oversized_image_reports_the_error_the_step_reported_before_test() {
  let path = "build/s6-oversized.png"
  let padding = image_drop.max_image_bytes + 1 - bit_array.byte_size(png)
  write(path, <<png:bits, 0:size(padding * 8)>>)
  let expected = image_drop.load_paste(path)
  let pasted = tui.update(backend.Paste(path), model())
  let _ = simplifile.delete(path)

  assert expected == Error("dropped image exceeds the 20 MiB limit")
  assert pasted.notice == "dropped image exceeds the 20 MiB limit"
  let assert Ok(tui_model.Line(tui_model.Failure, reason)) =
    list.last(pasted.transcript)
    as "the refusal is the transcript's newest line"
  assert reason == "dropped image exceeds the 20 MiB limit"
  assert image_names(pasted) == []
  assert textarea.value(pasted.input) == ""
}

// The read holds the image's bytes, so it must not stay on the model after
// the event it was taken for.
pub fn the_next_event_clears_the_read_test() {
  let path = "build/s6-cleared.png"
  write(path, png)
  let pasted = tui.update(backend.Paste(path), model())
  let _ = simplifile.delete(path)
  let assert image_drop.Dropped(read: Ok(Some(_)), ..) = pasted.dropped
    as "the paste's read is on the model the paste returned"
  let ticked = tui.update(backend.Tick, pasted)

  assert ticked.dropped == image_drop.NothingDropped
}

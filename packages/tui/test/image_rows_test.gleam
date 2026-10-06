//// An image's placeholder row, as whole frames.
////
//// A tool result owns the images the tool returned, so an image appears
//// under the call that returned it, as one row that names it: its place,
//// its media type, its pixel size read from its header, its byte size, and
//// the key that opens it outside the terminal. The row is always drawn, so
//// scrollback and replays stay text. Inside Herdr, which passes no pane
//// graphics through, a second row says so. The header reader is exercised
//// here too, on a PNG and a JPEG built byte by byte.

import core/json
import etui/backend
import frame_scene
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/image_header
import tui
import tui/frame
import tui/herdr
import tui/model as tui_model
import tui/view_set

// The opening of a PNG whose header says `width` by `height`.
fn png(width: Int, height: Int) -> String {
  <<
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13:32, "IHDR":utf8, width:32,
    height:32, 8, 6, 0, 0, 0, 0:size(1024)-unit(8),
  >>
  |> bit_array.base64_encode(True)
}

// A JPEG with an application segment before its start-of-frame.
fn jpeg(width: Int, height: Int) -> String {
  <<
    0xFF, 0xD8, 0xFF, 0xE0, 16:16, 0:size(14)-unit(8), 0xFF, 0xC0, 17:16, 8,
    height:16, width:16, 3, 0:size(9)-unit(8),
  >>
  |> bit_array.base64_encode(True)
}

pub fn the_header_gives_the_pixel_size_test() {
  assert image_header.dimensions(png(1200, 700)) == Some(#(1200, 700))
  assert image_header.dimensions(jpeg(640, 480)) == Some(#(640, 480))
  assert image_header.dimensions("bm90IGFuIGltYWdl") == None
  assert image_header.size_text(86_016) == "84 KB"
  assert image_header.size_text(1_258_291) == "1.2 MB"
}

fn scene() -> tui_model.Model {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Look at plots/latency.png."),
    frame_scene.assistant(2, "", [
      frame_scene.call("r1", "fs_read", [
        #("path", json.String("plots/latency.png")),
      ]),
    ]),
    frame_scene.result_images(3, "r1", "fs_read", [
      #("image/png", png(1200, 700)),
    ]),
    frame_scene.assistant(4, "The jump lines up with the deploy.", []),
  ])
}

pub fn an_image_is_one_row_under_its_call_test() {
  list.each([#(120, 40), #(80, 24)], fn(size) {
    let lines =
      frame_scene.screen(scene(), size.0, size.1) |> frame.buffer_to_lines
    let assert Ok(row) =
      list.find(lines, string.contains(_, "▣ image 1 · image/png · 1200×700"))
      as "the image's row names its type and size"
    assert string.contains(row, "o opens externally")
    assert !list.any(lines, string.contains(_, "Herdr"))
  })
}

pub fn inside_herdr_the_row_says_why_test() {
  let assert Ok(reporter) =
    herdr.start(herdr.Config(
      pane_id: "pane-7",
      socket_path: "/tmp/herdr-client.sock",
      started_ms: 1_757_000_000_000,
    ))
    as "the pane reporter starts outside Herdr too; it just never sends"
  let base = scene()
  let model =
    tui_model.Model(
      ..base,
      view: view_set.herdr_reporter(base.view, Some(reporter)),
    )
  let lines = frame_scene.screen(model, 80, 24) |> frame.buffer_to_lines
  assert list.any(lines, string.contains(
    _,
    "inside Herdr: pane graphics are not passed through",
  ))
}

// A response with prose draws its call inside itself and the result arrives
// as an entry of its own. The result is joined to the call: the call's row
// settles, the image's row follows it, and no row of the result's own says
// `[image image/png]`.
pub fn a_call_beside_prose_settles_with_its_image_test() {
  let model =
    frame_scene.attach(frame_scene.model(), "fix readme badge", [
      frame_scene.user(1, "Look at plots/latency.png."),
      frame_scene.assistant(2, "I will open the chart.", [
        frame_scene.call("r1", "fs_read", [
          #("path", json.String("plots/latency.png")),
        ]),
      ]),
      frame_scene.result_images(3, "r1", "fs_read", [
        #("image/png", png(1200, 700)),
      ]),
    ])
  let lines = frame_scene.screen(model, 120, 40) |> frame.buffer_to_lines
  assert list.any(lines, string.contains(_, "✓ fs_read · plots/latency.png"))
  assert list.any(lines, string.contains(_, "▣ image 1 · image/png · 1200×700"))
  assert !list.any(lines, string.contains(_, "[image image/png]"))
  assert !list.any(lines, string.contains(_, "● fs_read"))
}

// While reading above the tail, `o` starts the job that opens the newest
// image; at the tail, with nothing typed, it is a letter in the prompt.
pub fn o_opens_the_newest_image_while_reading_test() {
  let model = tui.update(backend.Resize(80, 12), scene())
  let reading = tui.update(backend.MouseScroll(5, 5, True), model)
  let opened = tui.update(backend.KeyPress("o"), reading)
  assert opened.view.opening_image != None
  let typed = tui.update(backend.KeyPress("o"), model)
  assert typed.view.opening_image == None
}

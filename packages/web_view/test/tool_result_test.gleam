//// The browser sees a bounded escaped result window and explicit access links.

import core/entry
import core/ids
import core/message
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/transcript_image
import session_view/transcript_line.{Line, Reasoning, System, ToolResult}
import session_view/transcript_lines
import session_view/turns
import web_view/component
import web_view/tool_result
import web_view/utf8_window
import web_view/view/expansion
import web_view/view/lane

pub fn unicode_prefixes_never_exceed_the_byte_budget_test() {
  list.each(["λ", "😀", "漢", "á"], fn(symbol) {
    let text = string.repeat(symbol, 100_000)
    let assert [Line(Reasoning, prefix), Line(System, _)] =
      expansion.capped([Line(Reasoning, text)])
      as "a large Unicode row has a bounded preview and its notice"
    assert string.byte_size(prefix) <= expansion.max_characters
    assert prefix == utf8_window.prefix(text, expansion.max_characters)
  })
}

pub fn adjacent_windows_partition_every_unicode_boundary_test() {
  let text = string.repeat("aλ😀漢́", 300)
  let bytes = bit_array.from_string(text)
  list.each(
    list.index_map(list.repeat(Nil, 23), fn(_, index) { index + 1 }),
    fn(stride) {
      let size = bit_array.byte_size(bytes)
      let count = { size + stride - 1 } / stride
      let joined =
        list.index_map(list.repeat(Nil, count), fn(_, index) { index })
        |> list.map(fn(index) {
          let assert Ok(text) =
            utf8_window.window(
              bytes,
              index * stride,
              int.min(size, { index + 1 } * stride),
            )
            as "each boundary gives valid UTF-8"
          text
        })
        |> string.join("")
      assert joined == text
    },
  )
}

pub fn viewer_escapes_output_and_offers_complete_download_and_navigation_test() {
  let drawn = tool_result.document("<script>alert(1)</script>λ", 1, 3, 48_000)
  assert !string.contains(drawn, "<script>")
  assert string.contains(drawn, "&lt;script&gt;")
  assert string.contains(drawn, "href=\"0\"")
  assert string.contains(drawn, "href=\"2\"")
  assert string.contains(drawn, "href=\"../download\"")
  assert string.contains(drawn, "Page 2 of 3")
}

pub fn large_result_keeps_html_bounded_and_links_its_immutable_record_test() {
  let source = "import cap/report\npub fn main() { report.text(\"hello\") }"
  let text = string.repeat("λ😀漢", 180_000) <> "FULL_RESULT_TAIL"
  let model =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.programmed(source, text)])
    |> lane_fixture.opened
  let drawn = component.view(model) |> element.to_string
  assert string.byte_size(drawn) < 100_000
  assert !string.contains(drawn, "FULL_RESULT_TAIL")
  assert string.contains(drawn, "View full result")
  assert string.contains(drawn, "Download result")
  let pieces = component.pieces(model)
  let refs =
    list.flat_map(pieces, fn(piece) {
      case piece {
        turns.Work(items:, ..) ->
          list.filter_map(items, fn(item) {
            case item {
              turns.Step(key:, result_source: Some(id), ..) ->
                Ok(#(transcript_image.ref(key), id))
              turns.Step(..) | turns.Narrated(..) | turns.Memory(..) ->
                Error(Nil)
            }
          })
        _ -> []
      }
    })
  let assert [#(ref, id)] = refs as "the drawn step names its immutable result"
  assert string.contains(
    drawn,
    "/result/" <> ids.entry_id_to_string(id) <> "/page/0",
  )
  assert ref != ""
}

pub fn a_result_whose_call_is_outside_the_window_keeps_full_access_test() {
  let assert Ok(id) = ids.parse_entry_id("0198c0de-0000-7000-8000-000000000001")
    as "the orphan result has an immutable identity"
  let record =
    entry.MessageEntry(
      id,
      None,
      3,
      1000,
      message.ToolResultMessage(
        "call",
        "code_mode",
        [message.ToolResultText("whole", None)],
        None,
        None,
        None,
        False,
        1000,
      ),
      False,
    )
  let block =
    transcript_lines.Block("3.0", transcript_lines.FromEntry(record), [
      #("3.0:0", Line(ToolResult, "summary")),
    ])
  assert turns.block_result(block) == Some(id)
  let html =
    lane.view(
      [turns.Plain(block, dict.new(), None)],
      [],
      lane.Beginning,
      Nil,
      lane.NoReplies,
      lane.no_marks(),
      lane.Folds(fn(_) { Nil }, fn(_) { Nil }, []),
      "session",
    )
    |> element.to_string
  assert string.contains(
    html,
    "/result/" <> ids.entry_id_to_string(id) <> "/download",
  )
}

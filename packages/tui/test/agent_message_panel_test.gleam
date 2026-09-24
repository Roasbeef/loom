//// Message browsing keeps durable selection and renders observed provenance.

import etui/backend
import etui/geometry
import etui/style
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/agent_message_panel
import tui/agent_messages
import tui/connection
import tui/layout
import tui/theme
import tui/workspace

fn item(
  source: String,
  entry_id: String,
  call_id: String,
  body: String,
  extent: agent_messages.BodyExtent,
  state: agent_messages.State,
  seq: Int,
) {
  agent_messages.Item(
    entry_id:,
    call_id:,
    source:,
    target: "worker",
    body:,
    body_extent: extent,
    seq:,
    state:,
  )
}

pub fn durable_selection_survives_fresh_arrivals_and_source_reuse_test() {
  let retained =
    item(
      "main",
      "entry-1",
      "call",
      "retained",
      agent_messages.Complete,
      agent_messages.Accepted,
      1,
    )
  let same_ids =
    item(
      "other",
      "entry-1",
      "call",
      "other",
      agent_messages.Complete,
      agent_messages.Started,
      2,
    )
  let fresh =
    item(
      "main",
      "entry-2",
      "new",
      "fresh",
      agent_messages.Complete,
      agent_messages.SendPending,
      3,
    )
  let key = agent_message_panel.identity(retained)
  let assert Some(selected) =
    agent_message_panel.selected([fresh, same_ids, retained], Some(key))
  assert selected.body == "retained"
  assert agent_message_panel.identity(same_ids) != key
}

pub fn every_state_and_excerpt_provenance_render_in_the_browser_test() {
  let messages = [
    item(
      "main",
      "4",
      "d",
      "started body",
      agent_messages.Excerpt,
      agent_messages.Started,
      4,
    ),
    item(
      "main",
      "3",
      "c",
      "accepted body",
      agent_messages.Complete,
      agent_messages.Accepted,
      3,
    ),
    item(
      "main",
      "2",
      "b",
      "failed body",
      agent_messages.Complete,
      agent_messages.SendFailed,
      2,
    ),
    item(
      "main",
      "1",
      "a",
      "pending body",
      agent_messages.Complete,
      agent_messages.SendPending,
      1,
    ),
  ]
  let area = geometry.rect_new(0, 0, 132, 24)
  let rendered = agent_message_panel.render(messages, None, 0, area)
  let text =
    rendered.lines
    |> list.map(fn(line) {
      line.spans |> list.map(fn(value) { value.content }) |> string.concat
    })
    |> string.join("\n")
  assert string.contains(text, "Started recipient run")
  assert string.contains(text, "started body")
  assert string.contains(text, "accepted body")
  assert string.contains(text, "Failed")
  assert string.contains(text, "Unknown")
  assert string.contains(text, "Retained excerpt")
  let selected = rendered.lines |> list.drop(2) |> list.first
  let assert Ok(selected) = selected
  let assert Ok(first) = list.first(selected.spans)
  assert string.starts_with(first.content, "▸ ")
  assert first.style.bg == theme.raised
  assert first.style.bg != style.Default

  // Each precise state remains readable in the selected preview while the
  // bounded list uses its short badge and a separate body excerpt row.
  let every_preview =
    messages
    |> list.map(fn(item) {
      agent_message_panel.render(
        messages,
        Some(agent_message_panel.identity(item)),
        0,
        area,
      ).lines
      |> list.map(fn(line) {
        line.spans |> list.map(fn(value) { value.content }) |> string.concat
      })
      |> string.join("\n")
    })
    |> string.join("\n")
  assert string.contains(every_preview, "Accepted by recipient")
  assert string.contains(every_preview, "Started recipient run")
  assert string.contains(every_preview, "Send failed")
  assert string.contains(every_preview, "Outcome unknown")
}

pub fn supported_viewports_bound_rows_and_page_without_gaps_test() {
  let numbered =
    int.range(0, 48, [], fn(lines, index) {
      ["line-" <> int.to_string(index), ..lines]
    })
    |> list.reverse
  let message =
    item(
      "main",
      "1",
      "a",
      string.join(numbered, "\n"),
      agent_messages.Complete,
      agent_messages.Accepted,
      1,
    )
  list.each([#(132, 42), #(80, 24), #(40, 12)], fn(size) {
    let model =
      tui.new_model_with_clock(
        connection.new_inbox(),
        workspace.Context("/work", None),
        fn() { 0 },
      )
      |> tui.update(backend.Resize(size.0, size.1), _)
    let area = layout.message_detail_area(model)
    let step = agent_message_panel.page_step(area)
    let pages = { list.length(numbered) + step - 1 } / step
    let visible =
      int.range(0, pages, [], fn(rows, page) {
        let rendered =
          agent_message_panel.render([message], None, page * step, area)
        let text =
          rendered.lines
          |> list.take(area.size.height)
          |> list.map(fn(line) {
            line.spans
            |> list.map(fn(value) { value.content })
            |> string.concat
          })
          |> string.join("\n")
        [text, ..rows]
      })
      |> string.join("\n")
    list.each(numbered, fn(line) {
      assert string.contains(visible, line)
    })
  })
}

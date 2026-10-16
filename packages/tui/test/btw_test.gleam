//// Side commands remain outside main submission and transcript projection.

import core/json
import etui/geometry
import etui/keys
import etui/span
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import session_view/btw
import session_view/command
import session_view/event_fold
import session_view/model as session_model
import session_view/protocol
import session_view/session_channel
import tui/effect
import tui/frame
import tui/interaction
import tui/layout
import tui/layout_memory
import tui/model as tui_model
import tui/render
import tui/selection
import tui_test/pushed

pub fn btw_grammar_and_palette_are_shared_with_web_test() {
  assert command.parse("/btw Why?")
    == command.Session(command.Btw(btw.Ask("Why?")))
  assert command.parse("/btw") == command.Session(command.Btw(btw.Read))
  assert command.parse("/btw refresh")
    == command.Session(command.Btw(btw.Refresh))
  assert command.parse("/btw cancel")
    == command.Session(command.Btw(btw.Cancel))
  assert list.any(command.suggestions("/bt"), fn(row) { row.command == "/btw" })
}

pub fn side_board_never_becomes_a_transcript_entry_test() {
  let model = pushed.attached()
  let board =
    btw.Board(
      "main",
      "source",
      "fixture",
      "ready",
      [btw.Exchange("Why?", "Because.")],
      "",
    )
  let before = model.shared
  let after = event_fold.apply_event(before, protocol.BtwSnapshot(board))
  assert after.transcript == before.transcript
  assert after.btw.board == Some(board)
  assert session_channel.is_read("btw")
  let assert Ok(decoded) = btw.decode(btw.encode(board)) as "board round trips"
  assert decoded == board
}

pub fn escape_hides_the_side_panel_without_aborting_main_test() {
  let model = pushed.attached()
  let model =
    tui_model.Model(
      ..model,
      shared: session_model.Shared(
        ..model.shared,
        btw: btw.State(..btw.new(), visibility: btw.Visible),
      ),
    )
  let after = interaction.update_ready_key(keys.Escape, model)
  assert after.shared.btw.visibility == btw.Hidden
  assert after.shared.outbox == model.shared.outbox
  assert after.shared.transcript == model.shared.transcript
}

pub fn oversized_or_malformed_boards_are_refused_test() {
  assert result.is_error(btw.decode(json.Null))
  let board =
    btw.Board(
      "main",
      "source",
      "fixture",
      "ready",
      [btw.Exchange("Why?", string.repeat("x", 32_769))],
      "",
    )
  assert result.is_error(btw.decode(btw.encode(board)))
}

// Distinct gutters make a full-height metadata slice observably wrong even
// when the selected main text happens to use the same speaker.
fn side_geometry_fixture() -> tui_model.Model {
  let base = pushed.attached()
  let rows =
    int.range(0, 100, [], fn(rows, n) {
      [
        span.line_plain(
          string.repeat(" ", 2 + n % 2) <> "row " <> int.to_string(n),
        ),
        ..rows
      ]
    })
  let gutters = int.range(0, 100, [], fn(rows, n) { [2 + n % 2, ..rows] })
  tui_model.Model(
    shared: session_model.Shared(
      ..base.shared,
      btw: btw.State(..btw.new(), visibility: btw.Visible),
    ),
    view: tui_model.View(
      ..base.view,
      width: 90,
      height: 30,
      clipboard: tui_model.TerminalClipboard,
      rendered_row_count: 100,
      revealed_rows: 100,
      rendered_gutters: gutters,
      caches: tui_model.Caches(..base.view.caches, rendered_rows: rows),
    ),
  )
}

pub fn side_panel_main_wheel_reaches_the_oldest_loaded_row_test() {
  let model = side_geometry_fixture()
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let main = render.transcript_area(model, screen)
  let at = main.position
  let scrolled =
    int.range(0, 100, model, fn(model, _) {
      interaction.scroll_at(model, at, tui_model.Older)
    })
  assert scrolled.view.scroll_offset == 100 - main.size.height
  let shown = render.render_frame(scrolled, screen).0
  assert frame.row_text(
      shown,
      main.position.x,
      main.position.y,
      main.size.width,
    )
    == "  row 0"
  assert list.length(render.transcript_window(scrolled, main))
    == main.size.height
  assert layout.transcript_viewport_height(scrolled) == main.size.height
}

pub fn side_panel_copy_preserves_its_prefix_and_main_gutters_test() {
  let model = side_geometry_fixture()
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, _, _) = layout.layout(screen, model)
  let #(conversation, _) = layout.queue_body_layout(body, model)
  let #(main, side) =
    layout.transcript_areas(layout.transcript_inner(conversation), model)
  assert layout.hit_area(model, side.position) == side
  assert layout.hit_area(model, main.position) == main
  let side_copy =
    interaction.begin_selection(model, side.position)
    |> interaction.finish_selection(geometry.Position(
      side.position.x + 12,
      side.position.y,
    ))
  assert list.contains(
    side_copy.view.outbox,
    effect.WriteClipboard(selection.clipboard_sequence("Side question")),
  )

  let gutters = interaction.selection_gutters_on_display(model)
  assert !list.any(gutters, fn(row) { row.0 >= side.position.y })
  let assert Ok(prefix) = list.key_find(gutters, main.position.y)
    as "each painted main row has its own gutter"
  assert prefix == 2 + { 100 - main.size.height } % 2
  let main_copy =
    interaction.begin_selection(model, main.position)
    |> interaction.finish_selection(geometry.Position(
      main.position.x + 20,
      main.position.y,
    ))
  assert list.contains(
    main_copy.view.outbox,
    effect.WriteClipboard(selection.clipboard_sequence(
      "row " <> int.to_string(100 - main.size.height),
    )),
  )
}

pub fn side_geometry_preserves_hidden_panel_and_reading_row_test() {
  let model = side_geometry_fixture()
  let area = geometry.rect_new(1, 1, 80, 20)
  let #(main, side) = layout.transcript_areas(area, model)
  assert main == geometry.rect_new(1, 1, 80, 10)
  assert side == geometry.rect_new(1, 11, 80, 10)
  let hidden =
    tui_model.Model(
      ..model,
      shared: session_model.Shared(..model.shared, btw: btw.new()),
    )
  assert layout.transcript_areas(area, hidden) == #(area, geometry.rect_zero())

  // The jump target stays in the panel's reserved row below the side text.
  let reading =
    tui_model.Model(
      ..model,
      view: tui_model.View(..model.view, scroll_offset: 10),
    )
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, _, _) = layout.layout(screen, reading)
  let #(conversation, _) = layout.queue_body_layout(body, reading)
  let jumped =
    interaction.begin_selection(
      reading,
      geometry.Position(
        conversation.position.x + 1,
        geometry.bottom(conversation) - 1,
      ),
    )
  assert jumped.view.scroll_offset == 0
}

// The rail narrows the side panel as well as the main transcript. Paging
// must count the rows actually painted or a permitted long answer loses its tail.
pub fn side_answer_tail_is_reachable_with_shown_and_hidden_rail_test() {
  list.each([layout_memory.RailShown, layout_memory.RailHidden], fn(rail) {
    let base = side_geometry_fixture()
    let board =
      btw.Board(
        "main",
        "source",
        "fixture",
        "ready",
        [
          btw.Exchange(
            "Why?",
            string.repeat("word ", 3000) <> "\nSIDE_ANSWER_TAIL",
          ),
        ],
        "",
      )
    let model =
      tui_model.Model(
        shared: session_model.Shared(
          ..base.shared,
          btw: btw.State(..base.shared.btw, board: Some(board)),
        ),
        view: tui_model.View(
          ..base.view,
          width: 160,
          height: 40,
          rail: Some(rail),
        ),
      )
    let screen = geometry.rect_new(0, 0, 160, 40)
    let #(_, seen) =
      int.range(0, 100, #(model, []), fn(acc, _) {
        let next = interaction.update_ready_key(keys.PageDown, acc.0)
        let lines = render.render_frame(next, screen).0 |> frame.buffer_to_lines
        #(next, list.append(acc.1, lines))
      })
    assert list.any(seen, string.contains(_, "SIDE_ANSWER_TAIL"))
      as "PageDown reaches the answer tail at the actual side width"
  })
}

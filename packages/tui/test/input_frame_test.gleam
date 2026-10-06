//// The identity line and the input frame, read off whole frames at 120 and
//// 80 columns. The identity line names what a screenshot shows; the frame's
//// rules carry what is live, so these tests pin where each fact sits, that
//// the frame is closed on all four sides, and what gives way first when a
//// rule runs out of room.

import etui/geometry
import frame_scene
import gleam/list
import gleam/option
import gleam/string
import session_view/shared_set
import tui/frame
import tui/input_frame
import tui/layout_memory
import tui/model as tui_model
import tui/view_set

fn attached() {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Fix the badge"),
    frame_scene.assistant(2, "Done.", []),
  ])
}

fn lines(model, width: Int, height: Int) -> List(String) {
  frame_scene.screen(model, width, height) |> frame.buffer_to_lines
}

fn row_starting(lines: List(String), prefix: String) -> String {
  let assert Ok(row) = list.find(lines, string.starts_with(_, prefix))
    as "the frame draws the row"
  row
}

pub fn the_identity_line_names_the_workspace_session_strand_and_model_test() {
  list.each([120, 80], fn(width) {
    let assert [identity, ..] = lines(attached(), width, 24)
      as "a frame has rows"
    assert string.starts_with(identity, " ◆ pi-gui · fix readme badge")
    assert string.contains(identity, "· strand main")
    assert string.ends_with(identity, "Kimi-K3 · low")
  })
}

pub fn the_input_frame_is_closed_and_carries_the_live_status_test() {
  list.each([#(120, 40), #(80, 24)], fn(size) {
    let shown = lines(attached(), size.0, size.1)
    let top = row_starting(shown, "╭─ To main · Enter sends")
    let middle = row_starting(shown, "│ ›")
    let bottom = row_starting(shown, "╰─")
    assert string.ends_with(top, "○ main · idle ─╮")
    assert string.ends_with(middle, "│")
    assert string.contains(middle, "/ commands")
    assert string.contains(bottom, "Kimi-K3")
    assert string.contains(bottom, "ctx —")
    assert string.ends_with(bottom, "─╯")
    assert !string.contains(bottom, "need you")
    assert string.length(top) == size.0
    assert string.length(bottom) == size.0

    // The footer is gone: with no strip, the frame's bottom rule is the
    // screen's last row.
    let assert Ok(last) = list.last(shown) as "a frame has rows"
    assert last == bottom
  })
}

pub fn a_wide_bottom_rule_names_the_effort_and_a_narrow_one_drops_it_test() {
  let wide = lines(attached(), 120, 40) |> row_starting("╰─")
  let narrow = lines(attached(), 80, 24) |> row_starting("╰─")
  assert string.contains(wide, "Kimi-K3 · low › ctx — › est —")
  assert string.contains(narrow, "Kimi-K3 › ctx — › —")
}

pub fn a_running_strand_names_what_it_is_doing_on_the_top_rule_test() {
  // The unattached demo model has a streaming primary strand.
  let shown = lines(frame_scene.model(), 120, 40)
  let top = row_starting(shown, "╭─ To main")
  assert string.contains(top, "Enter queues · Tab steers")
  assert string.contains(top, "streaming")
  assert string.contains(top, "Esc interrupts ─╮")
}

pub fn a_narrow_frame_keeps_the_activity_in_the_band_test() {
  let shown = lines(frame_scene.model(), 60, 24)
  let top = row_starting(shown, "╭─ To main")
  assert !string.contains(top, "streaming")
  assert list.any(shown, fn(row) {
    string.starts_with(row, "│") && string.contains(row, "streaming")
  })
}

pub fn the_prompt_leaves_the_editor_its_own_columns_test() {
  assert input_frame.prompt_area(geometry.rect_new(1, 5, 20, 1))
    == geometry.rect_new(4, 5, 16, 1)
}

// A long sub-strand recipient and the activity at the rule's far end have to
// share the rule of a 75-cell column, as they do beside a docked rail. The
// keys give way before the status does, and the recipient keeps its tail.
pub fn a_long_recipient_does_not_cost_the_frame_its_status_test() {
  let base = attached()
  let long = "sub:main/review-48f3a1b2"
  let model =
    tui_model.Model(
      shared: shared_set.active_strand(base.shared, long),
      view: view_set.rail(base.view, option.Some(layout_memory.RailShown)),
    )
  let shown = lines(model, 120, 40)
  let top = row_starting(shown, "╭─ To ")
  let column = string.slice(top, 0, 75)
  assert string.ends_with(column, "─╮")
  assert string.contains(column, "idle")
    as "the status survives the long recipient"
  assert string.contains(column, "48f3") as "the recipient keeps its suffix"
}

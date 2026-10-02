//// The approval block, read off whole frames at 120 and 80 columns: a
//// full-width block under a rule, directly above the input frame, with
//// numbered choices that select and never decide, and the input frame
//// locked while it is open.

import core/json
import etui/keys
import frame_scene
import gleam/list
import gleam/option.{None}
import gleam/string
import session_view/approval
import tui/approval_panel
import tui/frame
import tui/model as tui_model

fn review() -> approval.Review {
  approval.Review(
    "esc",
    7,
    approval.Pending,
    "bash",
    "fetch https://proxy.golang.org/gleam_stdlib/@v/list",
    None,
    approval.Exact("digest", [
      json.Object([
        #("type", json.String("readable_root")),
        #("path", json.String("/work/report")),
      ]),
    ]),
  )
}

fn deciding(panel: approval_panel.State) -> tui_model.Model {
  let base =
    frame_scene.attach(frame_scene.model(), "fix readme badge", [
      frame_scene.user(1, "Fetch the module list"),
      frame_scene.assistant(2, "Asking for network access.", []),
    ])
  tui_model.Model(
    ..base,
    view: tui_model.View(
      ..base.view,
      overlay: tui_model.ApprovalInspector(panel),
    ),
  )
}

fn index_of(lines: List(String), needle: String) -> Int {
  let assert Ok(#(index, _)) =
    lines
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(pair) { string.contains(pair.1, needle) })
    as "the frame draws the expected text"
  index
}

pub fn the_block_sits_above_the_locked_input_frame_test() {
  list.each([#(120, 40), #(80, 24)], fn(size) {
    let lines =
      frame_scene.screen(deciding(approval_panel.new(review())), size.0, size.1)
      |> frame.buffer_to_lines
    let rule = index_of(lines, "──────────")
    let once = index_of(lines, "1  Allow once")
    let deny = index_of(lines, "3  Deny")
    let keys = index_of(lines, "Enter decides")
    let frame = index_of(lines, "╭─ To main · locked while deciding")
    assert rule < once && once < deny && deny < keys && keys < frame
    assert frame == keys + 1
    assert index_of(lines, "grant") > rule
    assert list.all(lines, fn(line) { string.length(line) <= size.0 })
  })
}

pub fn a_number_selects_and_only_enter_decides_test() {
  let panel = approval_panel.new(review())
  let assert approval_panel.Continue(selected) =
    approval_panel.update(keys.Char("3"), panel)
    as "a number selects without deciding"
  let lines =
    frame_scene.screen(deciding(selected), 120, 40) |> frame.buffer_to_lines
  assert string.contains(lines |> string.join("\n"), "› 3  Deny")
  let assert approval_panel.Decide(_, approval_panel.Deny) =
    approval_panel.update(keys.Enter, selected)
    as "Enter decides the selected choice"
  let assert approval_panel.Continue(_) =
    approval_panel.update(keys.Enter, panel)
    as "Enter with nothing selected decides nothing"
}

//// The approval block, read off whole frames at 120 and 80 columns: a
//// full-width block under a rule, directly above the input frame, with
//// numbered choices that select and never decide, and the input frame
//// locked while it is open.

import core/json
import etui/geometry
import etui/keys
import frame_scene
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/approval
import session_view/shared_set
import tui/approval_panel
import tui/frame
import tui/layout
import tui/model as tui_model
import tui/view_set

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
    strand: None,
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
    view: view_set.overlay(base.view, tui_model.ApprovalInspector(panel)),
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
    let keys = index_of(lines, "Enter confirms")
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

// The heading names the strand whose call asked, and with a second
// question waiting it says which of them this is. An open question is
// something the operator owes, so the bottom rule counts it.
pub fn the_heading_names_the_asker_and_counts_the_queue_test() {
  let asked = approval.Review(..review(), strand: Some("sub:tests"))
  let other = approval.Review(..review(), id: "esc-2", strand: None)
  let base = deciding(approval_panel.new(asked))
  let model =
    tui_model.Model(
      ..base,
      shared: shared_set.approvals(base.shared, [asked, other]),
    )
  list.each([#(120, 40), #(80, 24)], fn(size) {
    let lines =
      frame_scene.screen(model, size.0, size.1) |> frame.buffer_to_lines
    let assert Ok(heading) =
      list.find(lines, string.contains(_, "? sub:tests · "))
      as "the heading names the asking strand"
    assert string.contains(heading, "1 of 2")
    assert list.any(lines, string.contains(_, "2 need you"))
  })
}

// A network grant is said in words, the hosts and how they are reached,
// rather than as the JSON the request carries.
pub fn a_network_grant_reads_as_words_test() {
  let asked =
    approval.Review(
      ..review(),
      permission: approval.Exact("digest", [
        json.Object([
          #("type", json.String("network")),
          #(
            "network",
            json.Object([
              #("mode", json.String("proxy")),
              #("allow", json.Array([json.String("proxy.golang.org:443")])),
              #("proxy", json.String("http://127.0.0.1:3128")),
            ]),
          ),
        ]),
      ]),
    )
  let lines =
    frame_scene.screen(deciding(approval_panel.new(asked)), 120, 40)
    |> frame.buffer_to_lines
  assert list.any(lines, string.contains(
    _,
    "net · proxy.golang.org:443 · via proxy",
  ))
  assert !list.any(lines, string.contains(_, "\"mode\""))
}

// The block spans the screen from the identity line to the input frame, so a
// docked rail beside it would leave its lower rows and its key hint stranded
// beside the frame. The rail steps aside in painting while an approval is
// open, and comes back when it is decided.
pub fn the_rail_steps_aside_while_an_approval_is_open_test() {
  let open = deciding(approval_panel.new(review()))
  let lines =
    frame_scene.screen(open, 200, 50)
    |> frame.buffer_to_lines
  let sized =
    tui_model.Model(
      ..open,
      view: open.view
        |> view_set.width(200)
        |> view_set.height(50),
    )
  assert layout.rail_columns(sized) == 57
    as "the rail's columns stay reserved so the transcript keeps its width"
  assert layout.rail_area(geometry.rect_new(0, 0, 200, 50), sized).size.width
    == 0
  assert !list.any(lines, string.contains(_, "STRANDS"))
  assert !list.any(lines, string.contains(_, "Shift+Tab hides"))

  // Closed again, the same terminal docks the rail by default.
  let closed =
    tui_model.Model(
      ..sized,
      view: view_set.overlay(sized.view, tui_model.NoOverlay),
    )
  assert layout.rail_columns(closed) == 57
}

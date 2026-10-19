//// Golden drawings for the Mermaid text renderer.
////
//// Each expected string is the rendering a reader sees, so a change to the
//// layout or the router shows up here as a picture rather than as a number.
//// The four cases are the ones a transcript most often holds: a plain chain,
//// a decision with labelled branches, a left-to-right flow with a cycle, and
//// a sequence diagram with a note.

import etui/span
import gleam/int
import gleam/list
import gleam/string
import tui/mermaid
import tui/mermaid/draw
import tui/mermaid/layout
import tui/mermaid/model
import tui/mermaid/parse

fn drawn(source: String, width: Int) -> String {
  let assert Ok(lines) = mermaid.render(source, width)
  text_of(lines)
}

fn text_of(lines: List(span.Line)) -> String {
  lines
  |> list.map(fn(line) {
    let span.Line(spans:, ..) = line
    spans |> list.map(fn(piece) { piece.content }) |> string.concat
  })
  |> string.join("\n")
}

fn refused(source: String, width: Int) -> model.Refusal {
  let assert Error(why) = mermaid.render(source, width)
  why
}

pub fn three_node_chain_test() {
  assert drawn("graph TD\nA[Start] --> B[Middle]\nB --> C[End]", 80)
    == string.join(
      [
        " ┌───────┐",
        " │ Start │",
        " └───────┘",
        "     │",
        "     │",
        "     ▼",
        "┌────────┐",
        "│ Middle │",
        "└────────┘",
        "     │",
        "     │",
        "     ▼",
        "  ┌─────┐",
        "  │ End │",
        "  └─────┘",
      ],
      "\n",
    )
}

pub fn decision_with_labelled_branches_test() {
  assert drawn(
      "graph TD\nA[Start] --> B{Ready?}\nB -->|yes| C[Go]\nB -->|no| D[Wait]",
      80,
    )
    == string.join(
      [
        "  ┌───────┐",
        "  │ Start │",
        "  └───────┘",
        "      │",
        "      │",
        "      ▼",
        " ╔════════╗",
        " ║ Ready? ║",
        " ╚════════╝",
        "   │     │",
        "   │     │ no",
        "   │ yes └───┐",
        "   ▼         ▼",
        "┌────┐    ┌──────┐",
        "│ Go │    │ Wait │",
        "└────┘    └──────┘",
      ],
      "\n",
    )
}

pub fn left_to_right_flow_with_a_cycle_test() {
  assert drawn("graph LR\nA[Build] --> B[Test]\nB --> C[Deploy]\nC --> A", 80)
    == string.join(
      [
        "┌───────┐                    ┌────────┐",
        "│       │                    │        │",
        "│       │      ┌──────┐      │        │",
        "│ Build │─────▶│ Test │─────▶│ Deploy │",
        "│       │      └──────┘      │        │",
        "│       │◀───────────────────│        │",
        "└───────┘                    └────────┘",
      ],
      "\n",
    )
}

pub fn sequence_with_a_note_test() {
  assert drawn(
      "sequenceDiagram\nparticipant U as User\nparticipant S as Server\nparticipant D as DB\nU->>S: login\nS-->>D: lookup\nNote over S,D: cached\nD-->>S: row\nS->>U: token",
      80,
    )
    == string.join(
      [
        "┌──────┐  ┌────────┐  ┌────┐",
        "│ User │  │ Server │  │ DB │",
        "└──────┘  └────────┘  └────┘",
        "    │ login    │         │",
        "    ├─────────▶│         │",
        "    │          │         │",
        "    │          │ lookup  │",
        "    │          ├┄┄┄┄┄┄┄┄▶│",
        "    │          │         │",
        "    │        ┌─────────────┐",
        "    │        │   cached    │",
        "    │        └─────────────┘",
        "    │          │         │",
        "    │          │ row     │",
        "    │          │◀┄┄┄┄┄┄┄┄┤",
        "    │          │         │",
        "    │ token    │         │",
        "    │◀─────────┤         │",
        "    │          │         │",
      ],
      "\n",
    )
}

// --- properties of the drawing that the goldens only imply ---------------

pub fn wide_characters_are_measured_in_cells_test() {
  let rows = drawn("graph LR\nA[日本語] --> B[Hello 🦊]", 80) |> string.split("\n")
  assert rows
    == [
      "┌────────┐     ┌──────────┐",
      "│ 日本語 │────▶│ Hello 🦊 │",
      "└────────┘     └──────────┘",
    ]
}

pub fn routes_cross_but_never_merge_test() {
  let picture = drawn("graph TD\nA --> D\nB --> C\nA --> C\nB --> D", 80)
  assert string.contains(picture, "┼")
  assert !string.contains(picture, "┬")
  assert !string.contains(picture, "┴")
  assert !string.contains(picture, "├")
  assert !string.contains(picture, "┤")
}

pub fn a_wide_flow_is_turned_to_fit_test() {
  // Left to right needs 36 cells; top down needs 12. Given 20 the renderer
  // draws the transposed layout instead of refusing.
  let rows = drawn("graph LR\nA[Build] --> B[Test]\nB --> C[Deploy]", 20)
  assert string.split(rows, "\n") |> list.length > 3
  assert !string.contains(rows, "────▶")
}

pub fn a_diagram_that_fits_no_layout_is_too_wide_test() {
  assert refused("graph TD\nA[a long enough label] --> B[another label]", 10)
    == model.TooWide
  assert refused("sequenceDiagram\nA->>B: hello there", 10) == model.TooWide
}

pub fn the_canvas_cap_refuses_before_routing_test() {
  // One root over 31 three-line labels of 40 cells is about 1,500 columns by
  // 45 rows top down, which is over the cap of 65,536 cells.
  let label = string.repeat("x", 40) <> "<br/>b<br/>c"
  let leaves =
    model.indices(31)
    |> list.map(fn(index) { "N" <> int.to_string(index) <> "[" <> label <> "]" })
  let source = "graph TD\nR --> " <> string.join(leaves, " & ")
  let assert Ok(model.Flow(chart)) = parse.parse(source)
  assert layout.place(chart, model.TopDown)
    == Error(model.TooLarge(model.CanvasCells))
}

pub fn reasons_are_short_phrases_test() {
  assert mermaid.reason(model.TooWide)
    == "not drawn: too wide for this terminal"
  assert mermaid.reason(model.Unsupported("`subgraph` statement"))
    == "not drawn: unsupported `subgraph` statement"
}

// --- the router's work is bounded ---------------------------------------

// The most search states the router may expand to draw a diagram at the caps,
// 32 nodes and 48 edges. Drawing such a diagram takes about 16,000 on the
// shapes below. The budget leaves room to double that and still sits two orders
// of magnitude under what a search over the whole canvas for every edge spent
// before the search was windowed and guided, so a change that brings the
// blow-up back fails here on a count, which does not vary with the machine.
const expansion_budget = 40_000

// A chart of 32 nodes and 48 edges whose targets are scattered by a multiplier,
// so edges skip layers, cross, and close cycles.
fn scattered(multiplier: Int) -> model.Flowchart {
  let lines =
    model.indices(48)
    |> list.map(fn(index) {
      let from = index % 32
      let to = { multiplier * index + 3 } % 32
      let target = case to == from {
        True -> { to + 1 } % 32
        False -> to
      }
      "N" <> int.to_string(from) <> " --> N" <> int.to_string(target)
    })
  let assert Ok(model.Flow(chart)) =
    parse.parse("graph TD\n" <> string.join(lines, "\n"))
  chart
}

// A direction may be refused as unroutable, and `mermaid.render` then draws the
// other, so each shape must draw in at least one direction and every drawing
// that succeeds must stay within the budget.
pub fn the_router_expands_a_bounded_number_of_states_test() {
  list.each([3, 7, 17, 29], fn(multiplier) {
    let drawn =
      [model.TopDown, model.LeftRight]
      |> list.filter_map(fn(direction) {
        draw.flowchart(scattered(multiplier), direction)
      })
    assert drawn != []
    list.each(drawn, fn(drawing) {
      assert drawing.expansions <= expansion_budget
    })
  })
}

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

pub fn a_wide_sequence_diagram_with_long_messages_wraps_to_fit_test() {
  let source =
    "sequenceDiagram
    participant P as Code-mode program
    participant M as client/mcp
    participant C as gleam_mcp/client
    participant H as client/mcp/http
    participant O as client/mcp/oauth
    participant S as Remote HTTP MCP Server
    P->>M: cap_call mcp.<server>
    M->>C: call_tool(name, args, timeout)
    C->>H: ChannelTransport send(JSON-RPC)
    H->>O: authorize / refresh under <server>.lock
    O-->>H: Bearer / Macaroon / NoAuth header
    H->>S: POST /mcp (Accept: json + sse, Mcp-Session-Id)
    S-->>H: 200 JSON or SSE stream (<= 8 MiB)
    H-->>C: correlated JSON-RPC response
    C-->>M: CallToolResult
    M-->>P: typed result or in-band refusal"
  list.each([80, 100, 120, 200], fn(width) {
    let picture = drawn(source, width)
    assert string.contains(picture, "POST")
    assert string.contains(picture, "▶")
  })
  let wide_picture = drawn(source, 120)
  assert string.contains(wide_picture, "POST /mcp")
  assert string.contains(wide_picture, "Mcp-Session-Id)")
  assert string.contains(wide_picture, "CallToolResult")
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

// Every direction is drawn from the whole-render budget, and what a direction
// spends is counted whether it drew or failed. A shape must draw in at least
// one direction, every drawing must stay within the expected work, and nothing
// may exceed the budget the renderer allows itself.
pub fn the_router_expands_a_bounded_number_of_states_test() {
  list.each([3, 7, 17, 29], fn(multiplier) {
    let outcomes =
      list.map([model.TopDown, model.LeftRight], fn(direction) {
        draw.flowchart(
          scattered(multiplier),
          direction,
          model.max_route_expansions,
        )
      })
    assert list.any(outcomes, fn(outcome) {
      case outcome {
        Ok(_) -> True
        Error(_) -> False
      }
    })
    list.each(outcomes, fn(outcome) {
      case outcome {
        Ok(drawing) -> {
          assert drawing.expansions <= expansion_budget
        }
        Error(draw.Failed(expansions:, ..)) -> {
          assert expansions <= model.max_route_expansions
        }
      }
    })
  })
}

// A long chain closed by six edges back to its start forces the back edges to
// run the length of the diagram, which is the shape that sends a search over
// the most cells. It must draw within the budget or be refused, and never
// spend more than the budget either way.
pub fn a_chain_with_back_edges_stays_within_the_budget_test() {
  let forward =
    model.indices(31)
    |> list.map(fn(index) {
      "N" <> int.to_string(index) <> " --> N" <> int.to_string(index + 1)
    })
  let back =
    model.indices(6)
    |> list.map(fn(index) { "N" <> int.to_string(31 - index) <> " --> N0" })
  let assert Ok(model.Flow(chart)) =
    parse.parse("graph TD\n" <> string.join(list.append(forward, back), "\n"))
  list.each([model.TopDown, model.LeftRight], fn(direction) {
    case draw.flowchart(chart, direction, model.max_route_expansions) {
      Ok(drawing) -> {
        assert drawing.expansions <= model.max_route_expansions
      }
      Error(draw.Failed(expansions:, ..)) -> {
        assert expansions <= model.max_route_expansions
      }
    }
  })
}

// Spending the whole budget is a refusal that names the work, and the count it
// reports is the budget, not more.
pub fn an_exhausted_budget_refuses_and_reports_what_it_spent_test() {
  let assert Error(draw.Failed(refusal:, expansions:)) =
    draw.flowchart(scattered(3), model.TopDown, 200)
  assert refusal == model.TooLarge(model.RoutingWork)
  assert expansions <= 200
}

pub fn an_empty_budget_draws_nothing_test() {
  let assert Error(draw.Failed(refusal:, expansions: 0)) =
    draw.flowchart(scattered(3), model.TopDown, 0)
  assert refusal == model.TooLarge(model.RoutingWork)
}

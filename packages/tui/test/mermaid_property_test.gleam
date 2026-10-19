//// Properties of the Mermaid text renderer.
////
//// The goldens in `mermaid_draw_test` pin four pictures. These tests pin what
//// has to hold for every input: the renderer is total, a drawing fits the width
//// it was given, every label that was drawn can be read back, the output is a
//// function of the input, and every edge of a small graph is connected in the
//// picture from its source box to its target box. The last is checked by
//// reading the finished text back into a grid and walking the line glyphs, so
//// it is independent of how the router built them.
////
//// The seed is fixed so the gate is deterministic. Generators draw enums as
//// bounded integers with the simplest variant at zero, so a failing case
//// shrinks toward a short diagram with plain edges.

import etui/span
import etui/text
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import qcheck
import tui/mermaid
import tui/mermaid/model

/// How many values each property is checked over, and the qcheck seed they are
/// drawn from. The seed is fixed so the gate is deterministic; to see another
/// sample, change the constant in a commit.
const cases = 150

const seed = 20_261_019

fn property(generator: qcheck.Generator(a), check: fn(a) -> Nil) -> Nil {
  qcheck.default_config()
  |> qcheck.with_test_count(cases)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(generator, check)
}

fn rows_of(lines: List(span.Line)) -> List(String) {
  list.map(lines, fn(line) {
    let span.Line(spans:, ..) = line
    spans |> list.map(fn(piece) { piece.content }) |> string.concat
  })
}

fn widest(rows: List(String)) -> Int {
  list.fold(rows, 0, fn(best, row) { int.max(best, text.cell_width(row)) })
}

// A drawing no wider than the room it was given.
fn fits(lines: List(span.Line), width: Int) -> Nil {
  assert widest(rows_of(lines)) <= width
}

// --- generators ----------------------------------------------------------

// Fragments a model might plausibly write, and some it should not. The first
// is the simplest, so a shrunk case is a lone identifier.
const fragments = [
  "A", "B", "C", " ", "\n", "-->", "---", "-.->", "==>", "->>", "-->>", "-x",
  ":", "|x|", "[x]", "{y}", "(z)", "&", "participant ", "Note over A,B: n",
  "subgraph s\n", "end\n", "%% c\n", "日本", " as ", "\u{0301}", "\"", ";",
  "<br/>", "((", "A[", "]",
]

const headers = ["graph TD\n", "flowchart LR\n", "sequenceDiagram\n"]

fn fragment_soup() -> qcheck.Generator(String) {
  let pick =
    qcheck.bounded_int(from: 0, to: list.length(fragments) - 1)
    |> qcheck.map(fn(index) { at(fragments, index, "A") })
  let header =
    qcheck.bounded_int(from: 0, to: list.length(headers) - 1)
    |> qcheck.map(fn(index) { at(headers, index, "graph TD\n") })
  let body =
    qcheck.generic_list(
      elements_from: pick,
      length_from: qcheck.bounded_int(from: 0, to: 24),
    )
    |> qcheck.map(string.concat)
  qcheck.map2(header, body, fn(head, rest) { head <> rest })
}

fn at(values: List(a), index: Int, fallback: a) -> a {
  case list.drop(values, index) {
    [found, ..] -> found
    [] -> fallback
  }
}

// A small directed graph as Mermaid source: two to five nodes, up to eight
// edges between distinct nodes with every stroke, tip and an optional label.
fn small_graph() -> qcheck.Generator(Graph) {
  qcheck.map3(
    qcheck.bounded_int(from: 0, to: 3),
    qcheck.bounded_int(from: 2, to: 5),
    qcheck.generic_list(
      elements_from: edge_choice(),
      length_from: qcheck.bounded_int(from: 0, to: 8),
    ),
    fn(direction, nodes, edges) { Graph(direction:, nodes:, edges:) },
  )
}

fn edge_choice() -> qcheck.Generator(#(Int, Int, Int, Int, Int)) {
  qcheck.tuple5(
    qcheck.bounded_int(from: 0, to: 4),
    qcheck.bounded_int(from: 1, to: 4),
    qcheck.bounded_int(from: 0, to: 2),
    qcheck.bounded_int(from: 0, to: 1),
    qcheck.bounded_int(from: 0, to: 2),
  )
}

type Graph {
  Graph(direction: Int, nodes: Int, edges: List(#(Int, Int, Int, Int, Int)))
}

fn graph_source(graph: Graph) -> String {
  let header =
    at(["graph TD", "graph BT", "graph LR", "graph RL"], graph.direction, "")
  let declarations =
    list.map(model.indices(graph.nodes), fn(index) {
      "N" <> int.to_string(index) <> "[node" <> int.to_string(index) <> "]"
    })
  let edges =
    graph.edges
    |> list.map(fn(choice) {
      let #(from, offset, stroke, tip, label) = choice
      let source = from % graph.nodes

      // The target is the source plus a step of one to nodes - 1, which keeps
      // it a different node.
      let target = { source + 1 + offset % { graph.nodes - 1 } } % graph.nodes
      #(source, target, stroke, tip, label)
    })
    |> distinct_pairs
    |> list.map(edge_line)
  string.join([header, ..list.append(declarations, edges)], "\n")
}

// Keeps the first edge between each unordered pair of nodes. Two edges between
// the same nodes share a channel and each wants a label beside its own line;
// that is a crowding the renderer may refuse, and it is not what these
// properties are about.
fn distinct_pairs(
  edges: List(#(Int, Int, Int, Int, Int)),
) -> List(#(Int, Int, Int, Int, Int)) {
  let #(kept, _) =
    list.fold(edges, #([], []), fn(state, edge) {
      let pair = #(int.min(edge.0, edge.1), int.max(edge.0, edge.1))
      case list.contains(state.1, pair) {
        True -> state
        False -> #([edge, ..state.0], [pair, ..state.1])
      }
    })
  list.reverse(kept)
}

fn edge_line(edge: #(Int, Int, Int, Int, Int)) -> String {
  let #(source, target, stroke, tip, label) = edge
  let operator = case stroke, tip {
    0, 0 -> "-->"
    0, _ -> "---"
    1, 0 -> "-.->"
    1, _ -> "-.-"
    _, 0 -> "==>"
    _, _ -> "==="
  }
  let name = case label {
    0 -> ""
    1 -> "|yes|"
    _ -> "|no|"
  }
  "N"
  <> int.to_string(source)
  <> " "
  <> operator
  <> name
  <> " N"
  <> int.to_string(target)
}

// --- properties ----------------------------------------------------------

pub fn render_is_total_and_fits_property_test() {
  property(
    qcheck.map2(
      fragment_soup(),
      qcheck.bounded_int(from: 1, to: 120),
      fn(source, width) { #(source, width) },
    ),
    fn(case_) {
      let #(source, width) = case_
      case mermaid.render(source, width) {
        Ok(lines) -> fits(lines, width)
        Error(_) -> Nil
      }
    },
  )
}

pub fn render_is_total_on_arbitrary_strings_property_test() {
  property(qcheck.string(), fn(source) {
    case mermaid.render(source, 80) {
      Ok(lines) -> fits(lines, 80)
      Error(_) -> Nil
    }
  })
}

pub fn small_graphs_are_drawn_whole_property_test() {
  property(small_graph(), fn(graph) {
    let source = graph_source(graph)
    let assert Ok(lines) = mermaid.render(source, 400)
    let picture = string.join(rows_of(lines), "\n")

    // Every node label is in the picture, and so is every edge label used.
    list.each(model.indices(graph.nodes), fn(index) {
      assert string.contains(picture, "node" <> int.to_string(index))
    })
    list.each(["yes", "no"], fn(label) {
      case string.contains(source, "|" <> label <> "|") {
        True -> {
          assert string.contains(picture, label)
        }
        False -> Nil
      }
    })

    // Two routes never merge: no tee glyph appears in a flowchart drawing.
    assert !list.any(["┬", "┴", "├", "┤"], string.contains(picture, _))
  })
}

pub fn drawings_fit_the_width_they_were_given_property_test() {
  property(
    qcheck.map2(
      small_graph(),
      qcheck.bounded_int(from: 8, to: 60),
      fn(graph, width) { #(graph, width) },
    ),
    fn(case_) {
      let #(graph, width) = case_
      case mermaid.render(graph_source(graph), width) {
        Ok(lines) -> fits(lines, width)
        Error(_) -> Nil
      }
    },
  )
}

pub fn output_is_deterministic_property_test() {
  property(small_graph(), fn(graph) {
    let source = graph_source(graph)
    assert mermaid.render(source, 100) == mermaid.render(source, 100)
  })
}

// --- edge reconstruction ---------------------------------------------------

// The six edges between three distinct nodes.
const possible_edges = [
  #("A", "B"),
  #("A", "C"),
  #("B", "A"),
  #("B", "C"),
  #("C", "A"),
  #("C", "B"),
]

fn subset(mask: Int) -> List(#(String, String)) {
  list.index_map(possible_edges, fn(edge, index) { #(edge, index) })
  |> list.filter_map(fn(entry) {
    case int.bitwise_and(mask, int.bitwise_shift_left(1, entry.1)) {
      0 -> Error(Nil)
      _ -> Ok(entry.0)
    }
  })
}

// Every directed graph on three nodes, in every direction, is drawn with each
// edge connected from its source box to its target box and with no edge
// connecting anything else. The check reads the text back, so it holds
// whatever the router did.
pub fn every_three_node_graph_reconstructs_test() {
  let directions = ["graph TD", "graph BT", "graph LR", "graph RL"]
  list.each(directions, fn(header) {
    list.each(model.indices(64), fn(mask) {
      let edges = subset(mask)
      let lines = list.map(edges, fn(edge) { edge.0 <> " --> " <> edge.1 })
      let source = string.join([header, "A", "B", "C", ..lines], "\n")
      let assert Ok(drawn) = mermaid.render(source, 400)
      assert reconstruct(rows_of(drawn)) == list.sort(edges, compare_edges)
    })
  })
}

fn compare_edges(a: #(String, String), b: #(String, String)) -> order.Order {
  string.compare(a.0 <> a.1, b.0 <> b.1)
}

type Grid =
  Dict(#(Int, Int), String)

type Boxes =
  Dict(String, #(Int, Int, Int, Int))

fn reconstruct(rows: List(String)) -> List(#(String, String)) {
  let grid =
    list.index_fold(rows, dict.new(), fn(table, row, y) {
      list.index_fold(string.to_graphemes(row), table, fn(inner, glyph, x) {
        case glyph {
          " " -> inner
          _ -> dict.insert(inner, #(x, y), glyph)
        }
      })
    })
  let boxes = find_boxes(grid)
  dict.keys(boxes)
  |> list.flat_map(fn(name) {
    walk_from(grid, boxes, name)
    |> list.map(fn(target) { #(name, target) })
  })
  |> list.sort(compare_edges)
}

// A node's box, found from its one-letter label by scanning outward to the
// first glyph in each direction: the outline.
fn find_boxes(grid: Grid) -> Boxes {
  dict.fold(grid, dict.new(), fn(found, at, glyph) {
    case glyph {
      "A" | "B" | "C" -> {
        let #(x, y) = at
        let left = scan(grid, x - 1, y, -1, 0)
        let right = scan(grid, x + 1, y, 1, 0)
        let top = scan(grid, x, y - 1, 0, -1)
        let bottom = scan(grid, x, y + 1, 0, 1)
        dict.insert(found, glyph, #(left.0, top.1, right.0, bottom.1))
      }
      _ -> found
    }
  })
}

fn scan(grid: Grid, x: Int, y: Int, dx: Int, dy: Int) -> #(Int, Int) {
  case dict.has_key(grid, #(x, y)) || x < -1000 || y < -1000 || x > 1000 {
    True -> #(x, y)
    False -> scan(grid, x + dx, y + dy, dx, dy)
  }
}

// Which sides of a cell a line glyph is open to, as unit steps.
fn openings(glyph: String) -> List(#(Int, Int)) {
  case glyph {
    "│" | "┆" | "┃" -> [#(0, -1), #(0, 1)]
    "─" | "┄" | "━" -> [#(-1, 0), #(1, 0)]
    "┌" | "┏" -> [#(0, 1), #(1, 0)]
    "┐" | "┓" -> [#(0, 1), #(-1, 0)]
    "└" | "┗" -> [#(0, -1), #(1, 0)]
    "┘" | "┛" -> [#(0, -1), #(-1, 0)]
    "┼" | "╋" -> [#(0, -1), #(0, 1), #(-1, 0), #(1, 0)]
    _ -> []
  }
}

fn arrow_step(glyph: String) -> Option(#(Int, Int)) {
  case glyph {
    "▼" -> Some(#(0, 1))
    "▲" -> Some(#(0, -1))
    "▶" -> Some(#(1, 0))
    "◀" -> Some(#(-1, 0))
    _ -> None
  }
}

// Every node a line leaving the named box ends at: each cell just outside the
// outline that is open toward the box starts a walk along the glyphs.
fn walk_from(grid: Grid, boxes: Boxes, name: String) -> List(String) {
  let #(left, top, right, bottom) =
    result.unwrap(dict.get(boxes, name), #(0, 0, 0, 0))
  let starts =
    list.flatten([
      list.map(span_of(left + 1, right - 1), fn(x) {
        #(#(x, bottom + 1), #(0, 1))
      }),
      list.map(span_of(left + 1, right - 1), fn(x) {
        #(#(x, top - 1), #(0, -1))
      }),
      list.map(span_of(top + 1, bottom - 1), fn(y) {
        #(#(left - 1, y), #(-1, 0))
      }),
      list.map(span_of(top + 1, bottom - 1), fn(y) {
        #(#(right + 1, y), #(1, 0))
      }),
    ])
  list.filter_map(starts, fn(start) {
    let #(cell, outward) = start
    case dict.get(grid, cell) {
      Ok(glyph) ->
        case list.contains(openings(glyph), #(0 - outward.0, 0 - outward.1)) {
          True -> follow(grid, boxes, cell, outward, 4000)
          False -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
}

fn span_of(low: Int, high: Int) -> List(Int) {
  case high < low {
    True -> []
    False ->
      list.map(model.indices(high - low + 1), fn(offset) { low + offset })
  }
}

// Follows a line from a cell it entered heading `heading`, to the box an
// arrowhead points into.
fn follow(
  grid: Grid,
  boxes: Boxes,
  cell: #(Int, Int),
  heading: #(Int, Int),
  fuel: Int,
) -> Result(String, Nil) {
  case fuel, dict.get(grid, cell) {
    0, _ -> Error(Nil)
    _, Error(_) -> Error(Nil)
    _, Ok(glyph) ->
      case arrow_step(glyph) {
        Some(step) if step == heading ->
          box_at(boxes, #(cell.0 + step.0, cell.1 + step.1))
        Some(_) -> Error(Nil)
        None -> {
          let entered = #(0 - heading.0, 0 - heading.1)
          let open = openings(glyph)
          case list.contains(open, entered) {
            False -> Error(Nil)
            True -> {
              let next = case glyph {
                "┼" | "╋" -> heading
                _ ->
                  list.find(open, fn(step) { step != entered })
                  |> result.unwrap(heading)
              }
              follow(
                grid,
                boxes,
                #(cell.0 + next.0, cell.1 + next.1),
                next,
                fuel - 1,
              )
            }
          }
        }
      }
  }
}

// The node whose outline contains a cell.
fn box_at(boxes: Boxes, cell: #(Int, Int)) -> Result(String, Nil) {
  dict.to_list(boxes)
  |> list.find(fn(entry) {
    let #(_, #(left, top, right, bottom)) = entry
    cell.0 >= left && cell.0 <= right && cell.1 >= top && cell.1 <= bottom
  })
  |> result.map(fn(entry) { entry.0 })
}

//// Flowchart drawing: boxes, routed edges and edge labels on one canvas.
////
//// `layout` has already decided where every box goes and how much room
//// the edges need, so drawing is a matter of painting the boxes first and then
//// routing the edges one at a time into the space they left. The order is
//// the design. Boxes go down first so that no route can pass through one.
//// Edges are routed shortest first, because a short edge has the fewest
//// choices and a long one can go around it, while the reverse would let a
//// long route wall off a short one. Each route is committed to the canvas
//// before the next is searched, which is how a later route sees an earlier
//// one as a line to cross or avoid, and each edge's label is placed
//// immediately after its route so that later routes also avoid the label.
////
//// An edge leaves its source on the side the diagram flows toward and arrives
//// at its target on the side it flows from. An edge that closes a cycle runs
//// the other way, leaving the source on the side facing against the flow and
//// arriving at the target's far side, so it reads as going back up the
//// diagram. Neither case needs special code in the router, which only sees
//// two boxes and two sides.
////
//// ## Flow
////
//// `flowchart` → `paint_boxes` → `route_edge` → `commit` → `place_label`
////
//// 1. `flowchart` asks `layout.place` for boxes and a grid size, then paints
////    each box with `canvas.draw_box`.
//// 2. `route_edge` picks the sides with `sides_for` and asks `route.find` for
////    a path.
//// 3. `commit` writes the path, with `arrow_glyph` at its end, and
//// 4. `place_label` writes the edge label beside a straight stretch of it.

import etui/text
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/result
import tui/mermaid/canvas.{type Canvas}
import tui/mermaid/layout.{type Placement}
import tui/mermaid/model.{
  type Box, type Direction, type Edge, type Flowchart, type Refusal,
}
import tui/mermaid/route.{type Side}

/// Draws a flowchart for a direction onto a canvas, or says why it cannot.
///
/// The caller crops and styles the canvas with `canvas.rows`. A routing
/// failure or a label with no free place to sit is `Unroutable`: the diagram
/// is refused whole rather than drawn with an edge missing.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(canvas) = draw.flowchart(chart, model.TopDown)
/// ```
pub fn flowchart(
  chart: Flowchart,
  direction: Direction,
) -> Result(Canvas, Refusal) {
  use placement <- result.try(layout.place(chart, direction))
  let painted = paint_boxes(chart, placement)
  let order = routing_order(chart.edges, placement.boxes)
  list.try_fold(order, painted, fn(current, index) {
    route_edge(current, chart, placement, index)
  })
}

fn paint_boxes(chart: Flowchart, placement: Placement) -> Canvas {
  let blank = canvas.new(placement.width, placement.height)
  list.zip(chart.nodes, placement.boxes)
  |> list.fold(blank, fn(current, pair) {
    canvas.draw_box(current, pair.1, { pair.0 }.shape, { pair.0 }.lines)
  })
}

// Edge indices from the nearest endpoints to the farthest, ties in source
// order. Short edges are routed first so that they get the direct path and a
// long edge goes around them.
fn routing_order(edges: List(Edge), boxes: List(Box)) -> List(Int) {
  edges
  |> list.index_map(fn(edge, index) {
    #(distance(box_at(boxes, edge.from), box_at(boxes, edge.to)), index)
  })
  |> list.sort(fn(a, b) {
    case int.compare(a.0, b.0) {
      order.Eq -> int.compare(a.1, b.1)
      other -> other
    }
  })
  |> list.map(fn(entry) { entry.1 })
}

fn distance(a: Box, b: Box) -> Int {
  int.absolute_value(a.x + a.width / 2 - b.x - b.width / 2)
  + int.absolute_value(a.y + a.height / 2 - b.y - b.height / 2)
}

fn box_at(boxes: List(Box), index: Int) -> Box {
  case list.drop(boxes, index) {
    [box, ..] -> box
    [] -> model.Box(0, 0, 0, 0)
  }
}

fn edge_at(edges: List(Edge), index: Int) -> Result(Edge, Refusal) {
  case list.drop(edges, index) {
    [edge, ..] -> Ok(edge)
    [] -> Error(model.Unroutable)
  }
}

fn flow_of(flows: List(layout.Flow), index: Int) -> layout.Flow {
  case list.drop(flows, index) {
    [flow, ..] -> flow
    [] -> layout.Forward
  }
}

fn route_edge(
  current: Canvas,
  chart: Flowchart,
  placement: Placement,
  index: Int,
) -> Result(Canvas, Refusal) {
  use edge <- result.try(edge_at(chart.edges, index))
  let #(exit, entry) =
    sides_for(placement.direction, flow_of(placement.flows, index))
  let source = box_at(placement.boxes, edge.from)
  let target = box_at(placement.boxes, edge.to)
  case route.find(current, source, exit, target, entry) {
    Error(_) -> Error(model.Unroutable)
    Ok(path) ->
      commit(current, path, exit, entry, edge)
      |> place_label(path, edge.label, placement.direction)
  }
}

// The side an edge leaves from and the side it arrives at. A forward edge
// leaves on the side the diagram flows toward; a backward one leaves on the
// opposite side and arrives on the flow side.
fn sides_for(direction: Direction, flow: layout.Flow) -> #(Side, Side) {
  let toward = case direction {
    model.TopDown -> route.Bottom
    model.BottomUp -> route.Top
    model.LeftRight -> route.Right
    model.RightLeft -> route.Left
  }
  case flow {
    layout.Forward -> #(toward, route.opposite(toward))
    layout.Backward -> #(route.opposite(toward), toward)
  }
}

// ---------------------------------------------------------------------------
// Writing a route
// ---------------------------------------------------------------------------

// The side bit a neighbouring cell lies on.
fn bit_toward(from: #(Int, Int), neighbour: #(Int, Int)) -> Int {
  case neighbour.0 - from.0, neighbour.1 - from.1 {
    1, _ -> canvas.right
    -1, _ -> canvas.left
    _, 1 -> canvas.down
    _, _ -> canvas.up
  }
}

// The bit that faces the box a side belongs to, from the cell beside it.
fn bit_into_box(side: Side) -> Int {
  case side {
    route.Top -> canvas.down
    route.Bottom -> canvas.up
    route.Left -> canvas.right
    route.Right -> canvas.left
  }
}

// Writes a route. Its first and last cells touch a box, so they become fixed
// glyphs no later route may cross; the cells between are crossable lines.
fn commit(
  current: Canvas,
  path: List(#(Int, Int)),
  exit: Side,
  entry: Side,
  edge: Edge,
) -> Canvas {
  let cells = list.length(path)
  list.index_fold(path, current, fn(painted, cell, position) {
    let previous = case list.drop(path, position - 1) {
      [before, ..] if position > 0 -> Some(before)
      _ -> option.None
    }
    let following = case list.drop(path, position + 1) {
      [after, ..] -> Some(after)
      [] -> option.None
    }
    let mask = case position == 0, position == cells - 1 {
      True, True -> bit_into_box(exit) + bit_into_box(entry)
      True, False -> bit_into_box(exit) + toward(cell, following)
      False, True -> toward(cell, previous) + bit_into_box(entry)
      False, False -> toward(cell, previous) + toward(cell, following)
    }
    case position == 0, position == cells - 1 {
      _, True -> end_glyph(painted, cell, mask, entry, edge)
      True, False ->
        canvas.put_ink(
          painted,
          cell.0,
          cell.1,
          canvas.line_glyph(mask, edge.stroke),
          canvas.Wire,
        )
      False, False ->
        canvas.add_line(painted, cell.0, cell.1, mask, edge.stroke)
    }
  })
}

fn toward(from: #(Int, Int), neighbour: option.Option(#(Int, Int))) -> Int {
  case neighbour {
    Some(other) -> bit_toward(from, other)
    option.None -> 0
  }
}

// The last cell of a route: an arrowhead facing the box, or the line itself
// for an edge with no arrowhead.
fn end_glyph(
  painted: Canvas,
  cell: #(Int, Int),
  mask: Int,
  entry: Side,
  edge: Edge,
) -> Canvas {
  case edge.tip {
    model.Arrow ->
      canvas.put_ink(painted, cell.0, cell.1, arrow_glyph(entry), canvas.Head)
    model.Open ->
      canvas.put_ink(
        painted,
        cell.0,
        cell.1,
        canvas.line_glyph(mask, edge.stroke),
        canvas.Wire,
      )
  }
}

// The arrowhead that points into the box on a side.
fn arrow_glyph(entry: Side) -> String {
  case entry {
    route.Top -> "▼"
    route.Bottom -> "▲"
    route.Left -> "▶"
    route.Right -> "◀"
  }
}

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

// Where along a route a label may sit, tried in this order.
type Spot {
  BesideVertical
  AboveHorizontal
  BelowHorizontal
}

// Writes an edge label beside the first stretch of the route with room for it.
// The label needs a blank cell on each side of its text, so it never touches
// a box, a line or another label. A vertical flow prefers the side of a
// vertical stretch and a horizontal flow the row above a horizontal one,
// because those are where the label reads as belonging to the line.
fn place_label(
  painted: Canvas,
  path: List(#(Int, Int)),
  label: String,
  direction: Direction,
) -> Result(Canvas, Refusal) {
  case label {
    "" -> Ok(painted)
    _ -> {
      let width = text.cell_width(label)
      let spots = case direction {
        model.TopDown | model.BottomUp -> [
          BesideVertical,
          AboveHorizontal,
          BelowHorizontal,
        ]
        model.LeftRight | model.RightLeft -> [
          AboveHorizontal,
          BelowHorizontal,
          BesideVertical,
        ]
      }
      let interior = from_the_middle(interior_cells(path))
      let straight =
        list.flat_map(spots, fn(spot) {
          list.filter_map(interior, fn(cell) {
            candidate(painted, cell, spot, width)
          })
        })

      // A route with no straight stretch long enough, such as a short hop
      // between two corners, takes its label beside any of its cells.
      let anywhere =
        list.flat_map(path, fn(cell) {
          [
            #(cell.0 + 2, cell.1, cell.0 + 1, cell.0 + width + 2),
            #(cell.0 - width - 1, cell.1, cell.0 - width - 2, cell.0 - 1),
          ]
        })
      first_free(painted, list.append(straight, anywhere), label)
    }
  }
}

fn interior_cells(path: List(#(Int, Int))) -> List(#(Int, Int)) {
  case path {
    [_, ..rest] -> list.take(rest, int.max(0, list.length(rest) - 1))
    [] -> []
  }
}

// The interior cells nearest the middle of the route first. A label by the
// first cell would sit against the box the route leaves, where it blocks the
// cells other edges need to reach that box's side; near the middle it is clear
// of both ends and reads as belonging to the edge as a whole.
fn from_the_middle(cells: List(#(Int, Int))) -> List(#(Int, Int)) {
  let middle = list.length(cells) / 2
  cells
  |> list.index_map(fn(cell, index) {
    #(int.absolute_value(index - middle), cell)
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(entry) { entry.1 })
}

// A label position for a spot at an interior cell, if that cell is a straight
// stretch of the right orientation. The result is where the text starts and
// the span of cells that must be blank, margins included.
fn candidate(
  painted: Canvas,
  cell: #(Int, Int),
  spot: Spot,
  width: Int,
) -> Result(#(Int, Int, Int, Int), Nil) {
  let #(x, y) = cell
  case canvas.cell(painted, x, y), spot {
    Some(canvas.Line(mask:, ..)), BesideVertical
      if mask == canvas.up + canvas.down
    -> Ok(#(x + 2, y, x + 1, x + width + 2))
    Some(canvas.Line(mask:, ..)), AboveHorizontal
      if mask == canvas.left + canvas.right
    -> Ok(#(x, y - 1, x - 1, x + width))
    Some(canvas.Line(mask:, ..)), BelowHorizontal
      if mask == canvas.left + canvas.right
    -> Ok(#(x, y + 1, x - 1, x + width))
    _, _ -> Error(Nil)
  }
}

// The first candidate whose whole span is blank, with the label written
// there. A candidate row is that of its text; the span runs across it.
fn first_free(
  painted: Canvas,
  candidates: List(#(Int, Int, Int, Int)),
  label: String,
) -> Result(Canvas, Refusal) {
  case candidates {
    [] -> Error(model.Unroutable)
    [#(x, y, from, to), ..rest] ->
      case canvas.region_blank(painted, from, y, to, y) {
        // The blank cells on each side are claimed with spaces, so a route
        // found later cannot run up against the label.
        True ->
          painted
          |> canvas.put_ink(from, y, " ", canvas.Plain)
          |> canvas.put_ink(to, y, " ", canvas.Plain)
          |> canvas.put_text(x, y, label, canvas.Label)
          |> Ok
        False -> first_free(painted, rest, label)
      }
  }
}

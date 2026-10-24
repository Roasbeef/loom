//// Flowchart placement: which layer each node is in and where its box sits.
////
//// Layout is separated from routing on purpose. This module decides only
//// where the boxes go and how much room the edges will need between them;
//// `route` then finds the actual paths on the resulting grid. That split
//// keeps cycles and long edges out of placement entirely: a cycle is broken
//// at a depth-first back edge so every node has a layer, and the broken edge
//// is still drawn, just routed against the flow, as the router sees it.
////
//// The method is the layered one. Each node's layer is the longest path to it
//// in the acyclic graph, a node with no incoming edge is pulled down next to
//// its first successor so it does not trail a long edge, and the nodes of a
//// layer are ordered by the mean position of their neighbours over a fixed
//// number of sweeps. Cross-axis positions then start from a centred packing
//// and move toward the mean centre of their neighbours over a fixed number
//// of passes, never closer together than the gap. Every loop is bounded by
//// the node count, the edge count or a pass count that is a constant.
////
//// Coordinates are computed on two axes, the one the diagram flows along and
//// the one across it, and mapped to columns and rows only at the end. That is
//// how top-down and left-right share one algorithm and differ in two lines.
////
//// ## Flow
////
//// `place` → `assign_layers` → `order_layers` → `along_positions` and
//// `cross_positions` → `to_boxes`
////
//// 1. `assign_layers` finds back edges with `find_back_edges` and takes
////    longest paths over the rest.
//// 2. `order_layers` sweeps barycenters down and up with `sweep_layer`.
//// 3. `along_positions` sizes each layer and the channel between layers,
////    using `channel_width` for the room edges and their labels need.
//// 4. `cross_positions` packs each layer, then `relax` pulls nodes toward
////    their neighbours.
//// 5. `to_boxes` turns the two coordinates into boxes for the direction.

import etui/text
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import tui/mermaid/model.{
  type Box, type Direction, type Edge, type Flowchart, type Node, type Refusal,
}

/// Whether an edge runs with the layering or against it. A backward edge is a
/// cycle's closing edge: the layering put its target above its source.
pub type Flow {
  Forward
  Backward
}

/// Where everything goes. `boxes` and `flows` are index-aligned with the
/// chart's nodes and edges. `width` and `height` are the routing grid's size,
/// margins included.
pub type Placement {
  Placement(
    direction: Direction,
    boxes: List(Box),
    flows: List(Flow),
    width: Int,
    height: Int,
  )
}

// Which axis the diagram flows along.
type Axis {
  Vertical
  Horizontal
}

// The two sides of a node across the flow axis: the one the flow heads toward
// and the one it comes from.
type FlowSide {
  Toward
  Away
}

// The layering's marks while the depth-first search runs.
type Visit {
  OnStack
  Finished
}

// How many ordering sweeps and cross-axis passes run. Both are constants so
// the work is bounded by the node count times these, never by the input.
const sweeps = 4

const passes = 4

/// Places a flowchart's nodes for a direction.
///
/// The direction is a parameter rather than the chart's own so the caller can
/// try the transposed one when the first does not fit the width.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(placement) = layout.place(chart, model.TopDown)
/// ```
pub fn place(
  chart: Flowchart,
  direction: Direction,
) -> Result(Placement, Refusal) {
  let axis = axis_of(direction)
  let nodes = chart.nodes
  let edges = chart.edges
  let back = find_back_edges(list.length(nodes), edges)
  let layer_of = assign_layers(list.length(nodes), edges, back)
  let layers = order_layers(group_layers(layer_of), edges, layer_of)
  let sizes = box_sizes(axis, nodes, edges, back)
  let channels = channel_sizes(axis, edges, layer_of, layers)

  let #(along, total_along) = along_positions(axis, sizes, layers, channels)
  let across = cross_positions(axis, sizes, layers, edges, layer_of)
  let extent = cross_extent(axis, sizes, across)
  let margin = margin_for(back)

  // An edge label sits beside a line, on either side of it, so the room for
  // the widest one is kept at both the left and the right.
  let room = label_room(edges)
  let boxes =
    to_boxes(direction, sizes, along, total_along, across)
    |> list.map(fn(box) { shift(box, margin + room, margin) })

  // Calculate bounding box dimensions based on layout axis orientation.
  let #(width, height) = case axis {
    Vertical -> #(extent + 2 * { margin + room }, total_along + 2 * margin)
    Horizontal -> #(total_along + 2 * { margin + room }, extent + 2 * margin)
  }

  // Guard against canvas allocations that exceed maximum allowed cells.
  case width * height > model.max_canvas_cells {
    True -> Error(model.TooLarge(model.CanvasCells))
    False ->
      Ok(Placement(
        direction:,
        boxes:,
        flows: list.index_map(edges, fn(_, index) {
          case set.contains(back, index) {
            True -> Backward
            False -> Forward
          }
        }),
        width:,
        height:,
      ))
  }
}

fn axis_of(direction: Direction) -> Axis {
  case direction {
    model.TopDown | model.BottomUp -> Vertical
    model.LeftRight | model.RightLeft -> Horizontal
  }
}

// The free border around the boxes. A closing edge of a cycle is routed
// outside the outermost boxes, and each one needs a lane of its own.
fn margin_for(back: Set(Int)) -> Int {
  2 + int.min(set.size(back), 6)
}

/// Extra room at the right for edge labels placed beside a line.
fn label_room(edges: List(Edge)) -> Int {
  case
    list.fold(edges, 0, fn(widest, edge) { int.max(widest, label_cells(edge)) })
  {
    0 -> 0
    widest -> widest + 4
  }
}

fn label_cells(edge: Edge) -> Int {
  text.cell_width(edge.label)
}

fn shift(box: Box, across: Int, down: Int) -> Box {
  model.Box(..box, x: box.x + across, y: box.y + down)
}

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

/// The edges that close a cycle: those that reach a node still on the search
/// stack. Dropping them leaves an acyclic graph, because every cycle must
/// contain one.
fn find_back_edges(count: Int, edges: List(Edge)) -> Set(Int) {
  let out =
    list.index_fold(edges, dict.new(), fn(table, edge, index) {
      let existing = result.unwrap(dict.get(table, edge.from), [])
      dict.insert(table, edge.from, list.append(existing, [#(index, edge.to)]))
    })
  let #(_, back) =
    list.fold(model.indices(count), #(dict.new(), set.new()), fn(state, node) {
      case dict.has_key(state.0, node) {
        True -> state
        False -> visit(node, out, state.0, state.1)
      }
    })
  back
}

/// Depth-first search step traversing outgoing edges to detect cycle-closing back edges.
fn visit(
  node: Int,
  out: Dict(Int, List(#(Int, Int))),
  marks: Dict(Int, Visit),
  back: Set(Int),
) -> #(Dict(Int, Visit), Set(Int)) {
  let entered = dict.insert(marks, node, OnStack)
  let #(marks, back) =
    list.fold(
      result.unwrap(dict.get(out, node), []),
      #(entered, back),
      fn(state, step) {
        let #(index, target) = step

        // Check target node visit status to identify back-edges.
        case dict.get(state.0, target) {
          Ok(OnStack) -> #(state.0, set.insert(state.1, index))
          Ok(Finished) -> state
          Error(_) -> visit(target, out, state.0, state.1)
        }
      },
    )
  #(dict.insert(marks, node, Finished), back)
}

/// Longest-path layers over the edges that are not back edges, then each node
/// without a predecessor moved down next to its nearest successor.
fn assign_layers(
  count: Int,
  edges: List(Edge),
  back: Set(Int),
) -> Dict(Int, Int) {
  let forward =
    edges
    |> list.index_map(fn(edge, index) { #(index, edge) })
    |> list.filter(fn(entry) { !set.contains(back, entry.0) })
    |> list.map(fn(entry) { entry.1 })
  let preds = adjacency(forward, fn(edge) { #(edge.to, edge.from) })
  let succs = adjacency(forward, fn(edge) { #(edge.from, edge.to) })
  let #(longest, _) =
    list.fold(model.indices(count), #(dict.new(), dict.new()), fn(state, node) {
      let #(value, memo) = depth(node, preds, state.1)
      #(dict.insert(state.0, node, value), memo)
    })
  list.fold(model.indices(count), longest, fn(table, node) {
    // Shift root nodes down towards their earliest successor layer.
    case dict.get(preds, node), dict.get(succs, node) {
      Error(_), Ok(next) -> {
        let lowest =
          list.fold(next, 1_000_000, fn(best, target) {
            int.min(best, result.unwrap(dict.get(longest, target), 0))
          })
        dict.insert(table, node, int.max(0, lowest - 1))
      }
      _, _ -> table
    }
  })
}

/// Constructs an adjacency dictionary from edges mapped by pair selector.
fn adjacency(
  edges: List(Edge),
  pair: fn(Edge) -> #(Int, Int),
) -> Dict(Int, List(Int)) {
  list.fold(edges, dict.new(), fn(table, edge) {
    let #(key, value) = pair(edge)
    let existing = result.unwrap(dict.get(table, key), [])
    dict.insert(table, key, list.append(existing, [value]))
  })
}

/// The length of the longest path ending at a node, memoised. The recursion is
/// as deep as the longest path, which the node limit bounds.
fn depth(
  node: Int,
  preds: Dict(Int, List(Int)),
  memo: Dict(Int, Int),
) -> #(Int, Dict(Int, Int)) {
  // Check if depth for this node has already been memoized.
  case dict.get(memo, node) {
    Ok(known) -> #(known, memo)
    Error(_) -> {
      let #(longest, memo) =
        list.fold(
          result.unwrap(dict.get(preds, node), []),
          #(0, memo),
          fn(state, pred) {
            let #(above, memo) = depth(pred, preds, state.1)
            #(int.max(state.0, above + 1), memo)
          },
        )
      #(longest, dict.insert(memo, node, longest))
    }
  }
}

/// Nodes grouped by layer, each layer in declaration order.
fn group_layers(layer_of: Dict(Int, Int)) -> Dict(Int, List(Int)) {
  let count = dict.size(layer_of)
  list.fold(model.indices(count), dict.new(), fn(table, node) {
    let layer = result.unwrap(dict.get(layer_of, node), 0)
    let existing = result.unwrap(dict.get(table, layer), [])
    dict.insert(table, layer, list.append(existing, [node]))
  })
}

fn layer_count(layers: Dict(Int, List(Int))) -> Int {
  dict.size(layers)
}

// ---------------------------------------------------------------------------
// Ordering within layers
// ---------------------------------------------------------------------------

/// Fixed sweeps of the barycenter heuristic: each layer is ordered by the mean
/// position of its neighbours in the layer just processed, down then up.
fn order_layers(
  layers: Dict(Int, List(Int)),
  edges: List(Edge),
  layer_of: Dict(Int, Int),
) -> Dict(Int, List(Int)) {
  let neighbours = neighbour_table(edges)
  let count = layer_count(layers)
  list.fold(model.indices(sweeps), layers, fn(current, _) {
    let down =
      list.fold(model.indices(count), current, fn(table, layer) {
        sweep_layer(table, layer, layer - 1, neighbours, layer_of)
      })
    list.fold(model.indices(count), down, fn(table, step) {
      let layer = count - 1 - step
      sweep_layer(table, layer, layer + 1, neighbours, layer_of)
    })
  })
}

/// Constructs undirected neighbour adjacency table for all flowchart edges.
fn neighbour_table(edges: List(Edge)) -> Dict(Int, List(Int)) {
  list.fold(edges, dict.new(), fn(table, edge) {
    let from_side = result.unwrap(dict.get(table, edge.from), [])
    let with_from = dict.insert(table, edge.from, [edge.to, ..from_side])
    let to_side = result.unwrap(dict.get(with_from, edge.to), [])
    dict.insert(with_from, edge.to, [edge.from, ..to_side])
  })
}

/// Reorders one layer by the mean index of each node's neighbours in the
/// reference layer. A node with none keeps its own index as its key, and ties
/// keep the current order, so a sweep never moves a node for no reason.
fn sweep_layer(
  layers: Dict(Int, List(Int)),
  layer: Int,
  reference: Int,
  neighbours: Dict(Int, List(Int)),
  layer_of: Dict(Int, Int),
) -> Dict(Int, List(Int)) {
  // Look up layer members and reference layer nodes.
  case dict.get(layers, layer), dict.get(layers, reference) {
    Ok(members), Ok(others) -> {
      let positions =
        list.index_fold(others, dict.new(), fn(table, node, index) {
          dict.insert(table, node, index)
        })
      let keyed =
        list.index_map(members, fn(node, index) {
          let found =
            result.unwrap(dict.get(neighbours, node), [])
            |> list.filter(fn(other) {
              result.unwrap(dict.get(layer_of, other), -1) == reference
            })
            |> list.filter_map(fn(other) { dict.get(positions, other) })
          #(barycenter(found, index), index, node)
        })
      let sorted =
        list.sort(keyed, fn(a, b) {
          case float.compare(a.0, b.0) {
            order.Eq -> int.compare(a.1, b.1)
            other -> other
          }
        })
      dict.insert(layers, layer, list.map(sorted, fn(entry) { entry.2 }))
    }
    _, _ -> layers
  }
}

fn barycenter(found: List(Int), fallback: Int) -> Float {
  case found {
    [] -> int.to_float(fallback)
    _ -> int.to_float(int.sum(found)) /. int.to_float(list.length(found))
  }
}

// ---------------------------------------------------------------------------
// Coordinates
// ---------------------------------------------------------------------------

// The size of a box along the flow axis and across it.
fn along_size(axis: Axis, size: #(Int, Int)) -> Int {
  case axis {
    Vertical -> size.1
    Horizontal -> size.0
  }
}

fn cross_size(axis: Axis, size: #(Int, Int)) -> Int {
  case axis {
    Vertical -> size.0
    Horizontal -> size.1
  }
}

/// A box size for each node, width then height. The label fixes the least size:
/// its widest line plus a border and a space on each side, by its line count
/// plus a border on each side. A node with several edges on one side needs more
/// along that side, because the router gives every edge a cell of its own and
/// keeps two of them from touching. The router takes ports from the middle
/// outward, alternating sides, so the side must reach `2 * (ports / 2)` cells
/// either way from the middle. The side runs across the flow axis, so it is the
/// width in a vertical flow and the height in a horizontal one.
fn box_sizes(
  axis: Axis,
  nodes: List(Node),
  edges: List(Edge),
  back: Set(Int),
) -> List(#(Int, Int)) {
  let demand = port_demand(edges, back)
  list.index_map(nodes, fn(node, index) {
    let widest =
      list.fold(node.lines, 1, fn(best, line) {
        int.max(best, text.cell_width(line))
      })
    let width = widest + 4
    let height = list.length(node.lines) + 2
    let ports = result.unwrap(dict.get(demand, index), 0)

    // Additional room needed along port side for multiple edge attachments.
    let room = case ports {
      0 | 1 -> 0
      _ -> 4 * { ports / 2 } + 3
    }

    // Map width and height to along/cross dimensions depending on flow axis.
    case axis {
      Vertical -> #(int.max(width, room), height)
      Horizontal -> #(width, int.max(height, room))
    }
  })
}

/// The most edges any one side of each node must hold. A forward edge leaves
/// its source on the side the flow heads toward and enters its target on the
/// other; a backward edge does the reverse, so both sides of a node can be
/// busy and the larger count is the one that sizes it.
fn port_demand(edges: List(Edge), back: Set(Int)) -> Dict(Int, Int) {
  let counts =
    list.index_fold(edges, dict.new(), fn(table, edge, index) {
      // Determine orientation of leaving/arriving ports depending on back-edge status.
      let #(leaving, arriving) = case set.contains(back, index) {
        True -> #(Away, Toward)
        False -> #(Toward, Away)
      }

      table
      |> bump(#(edge.from, leaving))
      |> bump(#(edge.to, arriving))
    })
  dict.fold(counts, dict.new(), fn(table, key, count) {
    let known = result.unwrap(dict.get(table, key.0), 0)
    dict.insert(table, key.0, int.max(known, count))
  })
}

fn bump(table: Dict(#(Int, FlowSide), Int), key: #(Int, FlowSide)) {
  dict.insert(table, key, result.unwrap(dict.get(table, key), 0) + 1)
}

/// A node's size along the flow axis, or across it, if the node has one. A
/// node without a size is left out of whatever is being summed or placed.
fn along_of(
  axis: Axis,
  sizes: List(#(Int, Int)),
  node: Int,
) -> Result(Int, Nil) {
  model.at(sizes, node) |> result.map(along_size(axis, _))
}

/// Returns a node's size perpendicular to the flow axis.
fn cross_of(
  axis: Axis,
  sizes: List(#(Int, Int)),
  node: Int,
) -> Result(Int, Nil) {
  model.at(sizes, node) |> result.map(cross_size(axis, _))
}

/// The room between layer `l` and layer `l + 1`: a lane for every edge that
/// crosses it, plus the arrow and a free row, and for a horizontal flow the
/// widest label of an edge crossing it, because the label sits on the line.
fn channel_sizes(
  axis: Axis,
  edges: List(Edge),
  layer_of: Dict(Int, Int),
  layers: Dict(Int, List(Int)),
) -> Dict(Int, Int) {
  list.fold(model.indices(layer_count(layers)), dict.new(), fn(table, boundary) {
    let crossing =
      list.filter(edges, fn(edge) {
        let a = result.unwrap(dict.get(layer_of, edge.from), 0)
        let b = result.unwrap(dict.get(layer_of, edge.to), 0)
        int.min(a, b) <= boundary && boundary < int.max(a, b)
      })
    dict.insert(table, boundary, channel_width(axis, crossing))
  })
}

/// Calculates channel width between layers accounting for crossing edge lanes and labels.
fn channel_width(axis: Axis, crossing: List(Edge)) -> Int {
  let lanes = list.length(crossing)
  let widest =
    list.fold(crossing, 0, fn(best, edge) { int.max(best, label_cells(edge)) })

  // Reserve lane and label space appropriate for the flow axis.
  case axis {
    Vertical -> 2 + lanes
    Horizontal -> 4 + lanes + widest
  }
}

/// Each node's start along the flow axis, and the total length. A layer is as
/// thick as its thickest node and a thinner node is centred within it.
fn along_positions(
  axis: Axis,
  sizes: List(#(Int, Int)),
  layers: Dict(Int, List(Int)),
  channels: Dict(Int, Int),
) -> #(Dict(Int, Int), Int) {
  let #(positions, end) =
    list.fold(
      model.indices(layer_count(layers)),
      #(dict.new(), 0),
      fn(state, layer) {
        let #(table, start) = state
        let members = result.unwrap(dict.get(layers, layer), [])
        let thickness =
          members
          |> list.filter_map(along_of(axis, sizes, _))
          |> list.fold(0, int.max)
        let placed =
          list.fold(members, table, fn(inner, node) {
            case along_of(axis, sizes, node) {
              Ok(size) ->
                dict.insert(inner, node, start + { thickness - size } / 2)
              Error(_) -> inner
            }
          })
        #(
          placed,
          start + thickness + result.unwrap(dict.get(channels, layer), 0),
        )
      },
    )
  #(positions, end - last_channel(channels, layers))
}

// The channel after the final layer leads nowhere, so it is not part of the
// diagram's length.
fn last_channel(channels: Dict(Int, Int), layers: Dict(Int, List(Int))) -> Int {
  result.unwrap(dict.get(channels, layer_count(layers) - 1), 0)
}

// The gap kept between neighbours in a layer.
fn cross_gap(axis: Axis) -> Int {
  case axis {
    Vertical -> 4
    Horizontal -> 3
  }
}

/// Each node's start across the flow axis: a centred packing, then a fixed
/// number of passes that move each node toward the mean centre of its
/// neighbours, left to right so the gap is always kept.
fn cross_positions(
  axis: Axis,
  sizes: List(#(Int, Int)),
  layers: Dict(Int, List(Int)),
  edges: List(Edge),
  layer_of: Dict(Int, Int),
) -> Dict(Int, Int) {
  let packed = pack(axis, sizes, layers)
  let neighbours = neighbour_table(edges)
  let count = layer_count(layers)
  let relaxed =
    list.fold(model.indices(passes), packed, fn(table, pass) {
      list.fold(model.indices(count), table, fn(inner, step) {
        // Alternate sweep direction between even and odd passes.
        let layer = case int.is_even(pass) {
          True -> step
          False -> count - 1 - step
        }

        relax(axis, sizes, layers, layer, neighbours, layer_of, inner)
      })
    })
  let lowest =
    list.fold(dict.values(relaxed), 1_000_000, fn(best, value) {
      int.min(best, value)
    })
  dict.map_values(relaxed, fn(_, value) { value - lowest })
}

/// Performs initial centered packing of nodes within their respective layers.
fn pack(
  axis: Axis,
  sizes: List(#(Int, Int)),
  layers: Dict(Int, List(Int)),
) -> Dict(Int, Int) {
  let rows =
    list.map(model.indices(layer_count(layers)), fn(layer) {
      result.unwrap(dict.get(layers, layer), [])
    })
  let lengths = list.map(rows, fn(members) { row_length(axis, sizes, members) })
  let widest = list.fold(lengths, 0, int.max)
  list.fold(list.zip(rows, lengths), dict.new(), fn(table, entry) {
    let #(members, length) = entry
    let #(placed, _) =
      list.fold(members, #(table, { widest - length } / 2), fn(state, node) {
        case cross_of(axis, sizes, node) {
          Ok(size) -> #(
            dict.insert(state.0, node, state.1),
            state.1 + size + cross_gap(axis),
          )
          Error(_) -> state
        }
      })
    placed
  })
}

fn row_length(axis: Axis, sizes: List(#(Int, Int)), members: List(Int)) -> Int {
  let widths = list.filter_map(members, cross_of(axis, sizes, _))
  int.sum(widths) + cross_gap(axis) * int.max(0, list.length(widths) - 1)
}

/// Moves one layer's nodes toward their neighbours' mean centre, then pushes
/// them apart left to right wherever that left less than the gap.
fn relax(
  axis: Axis,
  sizes: List(#(Int, Int)),
  layers: Dict(Int, List(Int)),
  layer: Int,
  neighbours: Dict(Int, List(Int)),
  layer_of: Dict(Int, Int),
  table: Dict(Int, Int),
) -> Dict(Int, Int) {
  let members = result.unwrap(dict.get(layers, layer), [])
  let desired =
    list.filter_map(members, fn(node) {
      use size <- result.map(cross_of(axis, sizes, node))
      let centres =
        result.unwrap(dict.get(neighbours, node), [])
        |> list.filter(fn(other) {
          result.unwrap(dict.get(layer_of, other), layer) != layer
        })
        |> list.filter_map(fn(other) {
          use start <- result.try(dict.get(table, other))
          use width <- result.map(cross_of(axis, sizes, other))
          start + width / 2
        })

      // Use centroid of connected neighbour centers, or retain existing position.
      case centres {
        [] -> #(node, result.unwrap(dict.get(table, node), 0), size)
        _ -> #(node, int.sum(centres) / list.length(centres) - size / 2, size)
      }
    })
  let #(placed, _) =
    list.fold(desired, #(table, None), fn(state, entry) {
      let #(inner, previous_end) = state
      let #(node, want, size) = entry

      // Ensure nodes maintain at least the required minimum cross-axis gap.
      let start = case previous_end {
        Some(end) -> int.max(want, end + cross_gap(axis))
        None -> want
      }

      #(dict.insert(inner, node, start), Some(start + size))
    })
  placed
}

/// Computes total bounding extent across all nodes perpendicular to flow axis.
fn cross_extent(
  axis: Axis,
  sizes: List(#(Int, Int)),
  across: Dict(Int, Int),
) -> Int {
  dict.fold(across, 0, fn(widest, node, start) {
    case cross_of(axis, sizes, node) {
      Ok(size) -> int.max(widest, start + size)
      Error(_) -> widest
    }
  })
}

/// Maps the two coordinates to boxes. A direction that runs against the axis
/// mirrors the flow coordinate so the first layer ends up last.
fn to_boxes(
  direction: Direction,
  sizes: List(#(Int, Int)),
  along: Dict(Int, Int),
  total_along: Int,
  across: Dict(Int, Int),
) -> List(Box) {
  let axis = axis_of(direction)
  list.index_map(sizes, fn(size, index) {
    let #(width, height) = size
    let flow_start = result.unwrap(dict.get(along, index), 0)
    let cross_start = result.unwrap(dict.get(across, index), 0)
    let mirrored = total_along - { flow_start + along_size(axis, size) }

    // Assign box coordinates according to direction and axis mirroring.
    case direction {
      model.TopDown -> model.Box(x: cross_start, y: flow_start, width:, height:)
      model.BottomUp -> model.Box(x: cross_start, y: mirrored, width:, height:)
      model.LeftRight ->
        model.Box(x: flow_start, y: cross_start, width:, height:)
      model.RightLeft -> model.Box(x: mirrored, y: cross_start, width:, height:)
    }
  })
}

//// Orthogonal edge routing on the character grid.
////
//// Routing is a shortest-path search, run once per edge over the cells the
//// canvas has left free. A turn costs more than a step and a crossing more
//// than a turn, so routes are short, straight where they can be, and cross
//// other routes only when going around costs more. A route may cross another
//// only at a cell that holds a straight line, moving perpendicular to it and
//// straight on through; it never runs along a line or ends on one. That one
//// rule is what guarantees two routes are never merged into a tee.
////
//// The search is a Dijkstra over states of position and heading, with a
//// bucket queue because every cost is a small integer. It is bounded three
//// ways, each of which matters because an unbounded routing loop once
//// exhausted the memory of another terminal renderer: it only visits cells
//// inside the canvas, it visits each position-and-heading state at most
//// once, and it gives up once the cost passes a limit proportional to the
//// canvas perimeter. A failed search is an ordinary `Error(Nil)`, which the
//// caller turns into a refusal.
////
//// A route starts on a free cell just outside one side of the source box and
//// ends on a free cell just outside one side of the target box, arriving
//// facing the box. Any free cell on those sides will do, with a small cost
//// for distance from the middle, so the search chooses the ports itself and
//// several edges on one side spread out rather than queue for one cell.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import tui/mermaid/canvas.{type Canvas}
import tui/mermaid/model.{type Box}

/// Which side of a box a route leaves from or arrives at.
pub type Side {
  Top
  Bottom
  Left
  Right
}

// What the search is looking for and how far it may look.
type Goal {
  Goal(cells: Dict(#(Int, Int), Int), heading: Int, limit: Int, width: Int)
}

// The search frontier: queued state keys by cost, the best known cost of each
// state, and the state each was reached from.
type Search {
  Search(
    queue: Dict(Int, List(Int)),
    best: Dict(Int, Int),
    came_from: Dict(Int, Int),
  )
}

// A step costs one, a turn three more, and crossing a line five more. The
// weights make a detour of up to a few cells preferable to a crossing, and a
// straight line preferable to a staircase.
const turn_cost = 3

const crossing_cost = 5

// The heading that is not a heading: a state at a goal cell, one step past
// the last cell of a route, so the search can finish in cost order.
const finished = 4

/// Finds a route from a free cell beside `from` to a free cell beside `to`.
///
/// The result lists the route's cells in order, the first cell beside the
/// source box and the last beside the target. It is `Error(Nil)` when no
/// route exists within the cost limit, which the caller reports as a
/// refusal.
///
/// ## Examples
///
/// ```gleam
/// route.find(canvas, source, route.Bottom, target, route.Top)
/// ```
pub fn find(
  canvas: Canvas,
  from: Box,
  exit: Side,
  to: Box,
  entry: Side,
) -> Result(List(#(Int, Int)), Nil) {
  let width = canvas.width(canvas)
  let starts =
    ports(canvas, from, exit)
    |> list.map(fn(port) { #(port.0, port.1, port.2) })
  let goal =
    Goal(
      cells: dict.from_list(
        list.map(ports(canvas, to, entry), fn(port) {
          #(#(port.0, port.1), port.2)
        }),
      ),
      heading: heading_of(opposite(entry)),
      limit: 8 * { width + canvas.height(canvas) } + 64,
      width:,
    )
  let search =
    list.fold(starts, empty_search(), fn(current, start) {
      let #(x, y, offset) = start
      push(current, key(width, x, y, heading_of(exit)), offset, None)
    })
  walk(canvas, goal, search, 0)
}

// The free cells just outside a side of a box, with each one's distance from
// the middle of that side. The corner columns are left out because a line
// there would read as touching the box's corner.
fn ports(canvas: Canvas, box: Box, side: Side) -> List(#(Int, Int, Int)) {
  let #(cells, centre) = case side {
    Top -> #(
      list.map(canvas.between(box.x + 1, box.x + box.width - 2), fn(x) {
        #(x, box.y - 1)
      }),
      box.x + box.width / 2,
    )
    Bottom -> #(
      list.map(canvas.between(box.x + 1, box.x + box.width - 2), fn(x) {
        #(x, box.y + box.height)
      }),
      box.x + box.width / 2,
    )
    Left -> #(
      list.map(canvas.between(box.y + 1, box.y + box.height - 2), fn(y) {
        #(box.x - 1, y)
      }),
      box.y + box.height / 2,
    )
    Right -> #(
      list.map(canvas.between(box.y + 1, box.y + box.height - 2), fn(y) {
        #(box.x + box.width, y)
      }),
      box.y + box.height / 2,
    )
  }

  // A port must be free and have a free cell on each side along the box, so
  // that two edges never leave or arrive in adjacent cells and read as one
  // thick line.
  cells
  |> list.filter(fn(cell) {
    let #(before, after) = case side {
      Top | Bottom -> #(#(cell.0 - 1, cell.1), #(cell.0 + 1, cell.1))
      Left | Right -> #(#(cell.0, cell.1 - 1), #(cell.0, cell.1 + 1))
    }
    canvas.is_blank(canvas, cell.0, cell.1)
    && !occupied(canvas, before)
    && !occupied(canvas, after)
  })
  |> list.map(fn(cell) {
    let offset = case side {
      Top | Bottom -> int.absolute_value(cell.0 - centre)
      Left | Right -> int.absolute_value(cell.1 - centre)
    }
    #(cell.0, cell.1, offset)
  })
}

// Whether something is drawn at a position inside the canvas. A position
// outside it is not occupied, only unusable, and the port test already
// accepts that.
fn occupied(canvas: Canvas, at: #(Int, Int)) -> Bool {
  case canvas.cell(canvas, at.0, at.1) {
    Some(_) -> True
    None -> False
  }
}

/// The side opposite another.
///
/// ## Examples
///
/// ```gleam
/// route.opposite(route.Top)
/// // -> route.Bottom
/// ```
pub fn opposite(side: Side) -> Side {
  case side {
    Top -> Bottom
    Bottom -> Top
    Left -> Right
    Right -> Left
  }
}

// Headings are small integers so a state packs into one key: north, south,
// west, east. A route that leaves a box through its top heads north.
fn heading_of(side: Side) -> Int {
  case side {
    Top -> 0
    Bottom -> 1
    Left -> 2
    Right -> 3
  }
}

fn step_of(heading: Int) -> #(Int, Int) {
  case heading {
    0 -> #(0, -1)
    1 -> #(0, 1)
    2 -> #(-1, 0)
    _ -> #(1, 0)
  }
}

// The heading that undoes a heading.
fn reverse_of(heading: Int) -> Int {
  case heading {
    0 -> 1
    1 -> 0
    2 -> 3
    _ -> 2
  }
}

fn key(width: Int, x: Int, y: Int, heading: Int) -> Int {
  { y * width + x } * 5 + heading
}

fn state_of(width: Int, packed: Int) -> #(Int, Int, Int) {
  let heading = packed % 5
  let cell = packed / 5
  #(cell % width, cell / width, heading)
}

fn empty_search() -> Search {
  Search(queue: dict.new(), best: dict.new(), came_from: dict.new())
}

// Queues a state if this is the cheapest way found to reach it.
fn push(search: Search, state: Int, cost: Int, parent: Option(Int)) -> Search {
  case dict.get(search.best, state) {
    Ok(known) if known <= cost -> search
    _ -> {
      let waiting = case dict.get(search.queue, cost) {
        Ok(states) -> states
        Error(_) -> []
      }
      Search(
        queue: dict.insert(search.queue, cost, [state, ..waiting]),
        best: dict.insert(search.best, state, cost),
        came_from: case parent {
          Some(from) -> dict.insert(search.came_from, state, from)
          None -> search.came_from
        },
      )
    }
  }
}

// Takes states from the cheapest non-empty bucket until the goal is popped,
// the cost limit passes, or the frontier empties. A state whose recorded cost
// has since improved is stale and is skipped.
fn walk(
  canvas: Canvas,
  goal: Goal,
  search: Search,
  cost: Int,
) -> Result(List(#(Int, Int)), Nil) {
  case cost > goal.limit {
    True -> Error(Nil)
    False ->
      case dict.get(search.queue, cost) {
        Ok([state, ..rest]) -> {
          let remaining =
            Search(..search, queue: dict.insert(search.queue, cost, rest))
          settle(canvas, goal, search, remaining, state, cost)
        }
        _ -> walk(canvas, goal, search, cost + 1)
      }
  }
}

// Handles one popped state. A state whose recorded cost is lower than the one
// it was queued at has been reached more cheaply since and is dropped.
fn settle(
  canvas: Canvas,
  goal: Goal,
  search: Search,
  remaining: Search,
  state: Int,
  cost: Int,
) -> Result(List(#(Int, Int)), Nil) {
  case dict.get(search.best, state) {
    Ok(known) if known == cost -> advance(canvas, goal, remaining, state, cost)
    _ -> walk(canvas, goal, remaining, cost)
  }
}

// Ends the search at the finish state, or queues what follows any other.
fn advance(
  canvas: Canvas,
  goal: Goal,
  remaining: Search,
  state: Int,
  cost: Int,
) -> Result(List(#(Int, Int)), Nil) {
  case state_of(goal.width, state) {
    #(_, _, heading) if heading == finished ->
      Ok(trace(goal.width, remaining, state, []))
    #(x, y, heading) ->
      walk(
        canvas,
        goal,
        expand(canvas, goal, remaining, state, #(x, y, heading), cost),
        cost,
      )
  }
}

// Queues what can follow a state. A state on a goal cell, heading into the
// box, queues the finish instead of moving on. A state on a crossing may only
// continue straight, because a turn there would join the two routes.
fn expand(
  canvas: Canvas,
  goal: Goal,
  search: Search,
  state: Int,
  at: #(Int, Int, Int),
  cost: Int,
) -> Search {
  let #(x, y, heading) = at
  case dict.get(goal.cells, #(x, y)) {
    Ok(offset) if heading == goal.heading ->
      push(search, key(goal.width, x, y, finished), cost + offset, Some(state))
    _ -> {
      let on_crossing = case canvas.cell(canvas, x, y) {
        Some(canvas.Line(..)) -> True
        _ -> False
      }
      list.fold([0, 1, 2, 3], search, fn(current, next) {
        case on_crossing, next == heading, next == reverse_of(heading) {
          True, False, _ | _, _, True -> current
          _, _, _ ->
            move(canvas, goal, current, state, #(x, y), next, heading, cost)
        }
      })
    }
  }
}

// One step in a heading, if the cell there can be entered that way. A free
// cell can; a straight line can, but only across it.
fn move(
  canvas: Canvas,
  goal: Goal,
  search: Search,
  state: Int,
  from: #(Int, Int),
  next: Int,
  heading: Int,
  cost: Int,
) -> Search {
  let #(dx, dy) = step_of(next)
  let #(nx, ny) = #(from.0 + dx, from.1 + dy)
  let turn = case next == heading {
    True -> 0
    False -> turn_cost
  }
  let entering = case
    canvas.contains(canvas, nx, ny),
    canvas.cell(canvas, nx, ny)
  {
    False, _ -> Error(Nil)
    True, None -> Ok(1 + hugging(canvas, nx, ny))
    True, Some(canvas.Line(mask:, ..)) ->
      case crossable(mask, next) {
        True -> Ok(1 + crossing_cost)
        False -> Error(Nil)
      }
    True, Some(_) -> Error(Nil)
  }
  case entering {
    Ok(price) ->
      push(
        search,
        key(goal.width, nx, ny, next),
        cost + price + turn,
        Some(state),
      )
    Error(_) -> search
  }
}

// One extra step of cost for a cell that touches a box's outline or an edge
// label, so a route that has a choice keeps a cell of space from them.
fn hugging(canvas: Canvas, x: Int, y: Int) -> Int {
  let touching =
    list.any([#(x - 1, y), #(x + 1, y), #(x, y - 1), #(x, y + 1)], fn(at) {
      case canvas.cell(canvas, at.0, at.1) {
        Some(canvas.Ink(role: canvas.Frame, ..)) -> True
        Some(canvas.Ink(role: canvas.Label, ..)) -> True
        _ -> False
      }
    })
  case touching {
    True -> 1
    False -> 0
  }
}

// A line can be crossed when it is straight and the crossing is square to it.
fn crossable(mask: Int, heading: Int) -> Bool {
  let vertical = mask == canvas.up + canvas.down
  let horizontal = mask == canvas.left + canvas.right
  case heading {
    0 | 1 -> horizontal
    _ -> vertical
  }
}

// Walks back from the finish to a start, collecting the cells in order. The
// finish state shares its cell with the last route cell, which is dropped
// once, and a start has no parent so the walk ends there.
fn trace(
  width: Int,
  search: Search,
  state: Int,
  cells: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  let #(x, y, heading) = state_of(width, state)
  let next = case heading == finished {
    True -> cells
    False -> [#(x, y), ..cells]
  }
  case dict.get(search.came_from, state) {
    Ok(parent) -> trace(width, search, parent, next)
    Error(_) -> next
  }
}

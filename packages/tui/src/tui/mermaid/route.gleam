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
//// The search is an A* over states of position and heading, with a bucket
//// queue because every cost is a small integer. The estimate is the distance
//// from a cell to the rectangle the target's ports lie in, which never exceeds
//// the true cost, so the first route found is still the cheapest, and it keeps
//// the search to the cells between the two boxes instead of every cell within
//// the route's cost of the source. It is bounded four ways, each of which
//// matters because an unbounded routing loop once exhausted the memory of
//// another terminal renderer, and because the terminal draws on its update
//// loop: it only visits cells inside a window around the two boxes, widened to
//// the whole canvas once if that finds nothing; it visits each
//// position-and-heading state at most once; it gives up once the cost passes
//// a limit proportional to the canvas perimeter; and it reports how many
//// states it expanded, so a test can bound the work without timing it. A failed
//// search is an ordinary `Error`, which the caller turns into a refusal.
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

/// A route found by `find`: its cells in order, and how many states the
/// search expanded to find it.
pub type Found {
  Found(cells: List(#(Int, Int)), expansions: Int)
}

// What the search is looking for and where it may look. `window` is the
// rectangle of cells it may enter, as left, top, right, bottom, and `target`
// the rectangle the goal cells lie in, which the estimate measures against.
type Goal {
  Goal(
    cells: Dict(#(Int, Int), Int),
    heading: Int,
    limit: Int,
    width: Int,
    window: #(Int, Int, Int, Int),
    target: #(Int, Int, Int, Int),
  )
}

// The search frontier: queued state keys by estimated total cost, the best
// known cost to reach each state, the state each was reached from, and how
// many states have been expanded.
type Search {
  Search(
    queue: Dict(Int, List(Int)),
    best: Dict(Int, Int),
    came_from: Dict(Int, Int),
    expanded: Int,
  )
}

// A state taken from the queue: its key, where it is, the heading it arrived
// with, and what it cost to get there.
type Walker {
  Walker(state: Int, x: Int, y: Int, heading: Int, cost: Int)
}

// How far past the two boxes the first search may look. Most routes run
// between neighbouring layers, so a window this wide holds them with room to
// go around a box; a route that needs more is found by the second attempt.
const window_margin = 4

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
/// source box and the last beside the target, with the number of states
/// expanded. It is `Error` when no route exists within the cost limit, which
/// the caller reports as a refusal, and the error carries the expansions spent
/// finding that out.
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
) -> Result(Found, Int) {
  let starts = ports(canvas, from, exit)
  let goals = ports(canvas, to, entry)
  let near = window_around(from, to, canvas)
  case attempt(canvas, starts, goals, exit, entry, near) {
    Ok(found) -> Ok(found)
    Error(spent) -> {
      let whole = #(0, 0, canvas.width(canvas) - 1, canvas.height(canvas) - 1)
      case near == whole {
        True -> Error(spent)
        False ->
          case attempt(canvas, starts, goals, exit, entry, whole) {
            Ok(found) ->
              Ok(Found(..found, expansions: found.expansions + spent))
            Error(more) -> Error(spent + more)
          }
      }
    }
  }
}

// The window of the first attempt: the two boxes and a margin, kept inside the
// canvas.
fn window_around(from: Box, to: Box, canvas: Canvas) -> #(Int, Int, Int, Int) {
  #(
    int.max(0, int.min(from.x, to.x) - window_margin),
    int.max(0, int.min(from.y, to.y) - window_margin),
    int.min(
      canvas.width(canvas) - 1,
      int.max(from.x + from.width, to.x + to.width) + window_margin,
    ),
    int.min(
      canvas.height(canvas) - 1,
      int.max(from.y + from.height, to.y + to.height) + window_margin,
    ),
  )
}

// One search inside a window. Ports outside the window are not used.
fn attempt(
  canvas: Canvas,
  starts: List(#(Int, Int, Int)),
  goals: List(#(Int, Int, Int)),
  exit: Side,
  entry: Side,
  window: #(Int, Int, Int, Int),
) -> Result(Found, Int) {
  let width = canvas.width(canvas)
  let usable = fn(port: #(Int, Int, Int)) {
    port.0 >= window.0
    && port.0 <= window.2
    && port.1 >= window.1
    && port.1 <= window.3
  }
  let reachable = list.filter(goals, usable)
  let target = bounds_of(reachable)
  let goal =
    Goal(
      cells: dict.from_list(
        list.map(reachable, fn(port) { #(#(port.0, port.1), port.2) }),
      ),
      heading: heading_of(opposite(entry)),
      limit: 8 * { width + canvas.height(canvas) } + 64,
      width:,
      window:,
      target:,
    )
  let search =
    list.fold(list.filter(starts, usable), empty_search(), fn(current, start) {
      let #(x, y, offset) = start
      push(
        current,
        key(width, x, y, heading_of(exit)),
        offset,
        estimate_at(goal, x, y),
        None,
      )
    })
  case reachable {
    [] -> Error(0)
    _ -> walk(canvas, goal, search, 0)
  }
}

// The smallest rectangle holding every port, as left, top, right, bottom.
fn bounds_of(ports: List(#(Int, Int, Int))) -> #(Int, Int, Int, Int) {
  case ports {
    [] -> #(0, 0, 0, 0)
    [first, ..rest] ->
      list.fold(rest, #(first.0, first.1, first.0, first.1), fn(box, port) {
        #(
          int.min(box.0, port.0),
          int.min(box.1, port.1),
          int.max(box.2, port.0),
          int.max(box.3, port.1),
        )
      })
  }
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
  Search(
    queue: dict.new(),
    best: dict.new(),
    came_from: dict.new(),
    expanded: 0,
  )
}

// The least a route can still cost from a cell: its distance to the rectangle
// the goal cells lie in. Every step costs at least one, so this never
// overestimates, and it changes by at most one per step, so the first time a
// state is taken from the queue its cost is final.
fn estimate(goal: Goal, state: Int) -> Int {
  let #(x, y, _) = state_of(goal.width, state)
  estimate_at(goal, x, y)
}

fn estimate_at(goal: Goal, x: Int, y: Int) -> Int {
  let #(left, top, right, bottom) = goal.target
  int.max(0, int.max(left - x, x - right))
  + int.max(0, int.max(top - y, y - bottom))
}

// Queues a state if this is the cheapest way found to reach it. It waits in the
// bucket of its cost so far plus `remaining`, the estimate for its cell, which
// the caller already has the coordinates to work out.
fn push(
  search: Search,
  state: Int,
  cost: Int,
  remaining: Int,
  parent: Option(Int),
) -> Search {
  case dict.get(search.best, state) {
    Ok(known) if known <= cost -> search
    _ -> {
      let priority = cost + remaining
      let waiting = case dict.get(search.queue, priority) {
        Ok(states) -> states
        Error(_) -> []
      }
      Search(
        ..search,
        queue: dict.insert(search.queue, priority, [state, ..waiting]),
        best: dict.insert(search.best, state, cost),
        came_from: case parent {
          Some(from) -> dict.insert(search.came_from, state, from)
          None -> search.came_from
        },
      )
    }
  }
}

// Takes states from the lowest non-empty priority bucket until the goal is
// popped, the limit passes, or the frontier empties. A state whose best cost
// has since improved is stale: it was queued under a priority that no longer
// matches, and is skipped.
fn walk(
  canvas: Canvas,
  goal: Goal,
  search: Search,
  priority: Int,
) -> Result(Found, Int) {
  case priority > goal.limit {
    True -> Error(search.expanded)
    False ->
      case dict.get(search.queue, priority) {
        Ok([state, ..rest]) -> {
          let remaining =
            Search(..search, queue: dict.insert(search.queue, priority, rest))
          settle(canvas, goal, remaining, state, priority)
        }
        _ -> walk(canvas, goal, search, priority + 1)
      }
  }
}

// Handles one popped state, unless its priority is out of date.
fn settle(
  canvas: Canvas,
  goal: Goal,
  remaining: Search,
  state: Int,
  priority: Int,
) -> Result(Found, Int) {
  let current = priority - estimate(goal, state)
  case dict.get(remaining.best, state) {
    Ok(known) if known == current ->
      advance(canvas, goal, remaining, state, known, priority)
    _ -> walk(canvas, goal, remaining, priority)
  }
}

// Ends the search at the finish state, or queues what follows any other.
fn advance(
  canvas: Canvas,
  goal: Goal,
  remaining: Search,
  state: Int,
  cost: Int,
  priority: Int,
) -> Result(Found, Int) {
  case state_of(goal.width, state) {
    #(_, _, heading) if heading == finished ->
      Ok(Found(
        cells: trace(goal.width, remaining, state, []),
        expansions: remaining.expanded,
      ))
    #(x, y, heading) ->
      walk(
        canvas,
        goal,
        expand(
          canvas,
          goal,
          Search(..remaining, expanded: remaining.expanded + 1),
          Walker(state:, x:, y:, heading:, cost:),
        ),
        priority,
      )
  }
}

// Queues what can follow a state. A state on a goal cell, heading into the
// box, queues the finish instead of moving on. A state on a crossing may only
// continue straight, because a turn there would join the two routes.
fn expand(canvas: Canvas, goal: Goal, search: Search, at: Walker) -> Search {
  case dict.get(goal.cells, #(at.x, at.y)) {
    Ok(offset) if at.heading == goal.heading ->
      push(
        search,
        key(goal.width, at.x, at.y, finished),
        at.cost + offset,
        0,
        Some(at.state),
      )
    _ -> {
      let on_crossing = case canvas.cell(canvas, at.x, at.y) {
        Some(canvas.Line(..)) -> True
        _ -> False
      }
      list.fold([0, 1, 2, 3], search, fn(current, next) {
        case on_crossing, next == at.heading, next == reverse_of(at.heading) {
          True, False, _ | _, _, True -> current
          _, _, _ -> move(canvas, goal, current, at, next)
        }
      })
    }
  }
}

// One step in a heading, if the cell there can be entered that way. A free
// cell can; a straight line can, but only across it. The extra cost of a cell
// beside a box is only worked out for a step that could improve on what the
// state already costs, because most steps reach states already settled.
fn move(
  canvas: Canvas,
  goal: Goal,
  search: Search,
  at: Walker,
  next: Int,
) -> Search {
  let #(dx, dy) = step_of(next)
  let #(nx, ny) = #(at.x + dx, at.y + dy)
  let arriving = key(goal.width, nx, ny, next)
  let turn = case next == at.heading {
    True -> 0
    False -> turn_cost
  }
  let inside =
    nx >= goal.window.0
    && ny >= goal.window.1
    && nx <= goal.window.2
    && ny <= goal.window.3
  let settled = case dict.get(search.best, arriving) {
    Ok(known) -> known <= at.cost + 1 + turn
    Error(_) -> False
  }
  let entering = case inside && !settled, canvas.cell(canvas, nx, ny) {
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
        arriving,
        at.cost + price + turn,
        estimate_at(goal, nx, ny),
        Some(at.state),
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

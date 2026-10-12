//// The data behind a figure's drawing, and the geometry that turns it into
//// lines.
////
//// A diagram is a set of boxes laid out twice, once for a wide container
//// and once for a narrow one, a set of links between boxes, and one frame
//// per step. A frame says what state every box is in at that step and which
//// links carry a message. Nothing here draws: `site/diagram_view` reads this
//// data, and the test suite reads it too, so a typo in a box id or a box
//// placed on top of another fails `gleam test` and not a visitor's page.
////
//// Links have no coordinates of their own. `route` derives a straight or
//// bent path from the two rectangles of the active layout, so moving a box
//// does not mean redrawing its lines by hand.
////
//// ## Flow
////
//// - `Diagram` is the whole figure, `Node` a box and `Frame` one step.
//// - `rect_of` picks a node's rectangle in a layout.
//// - `route` and `label_point` turn two rectangles into a path.
//// - `state_of`, `find_node` and `find_link` look things up by id.
//// - `text_height` estimates whether a box's words fit it, which the tests
////   use because a browser is not available to them.

import gleam/list
import gleam/option.{type Option}
import gleam/string

/// A rectangle in layout units. A layout unit is one CSS pixel when the
/// drawing is shown at its design width. A zero-sized rectangle means that
/// the node is not drawn in that layout.
pub type Rect {
  Rect(x: Int, y: Int, w: Int, h: Int)
}

/// The design size of each of the two layouts, in layout units.
pub type Sizes {
  Sizes(wide_w: Int, wide_h: Int, narrow_w: Int, narrow_h: Int)
}

/// What a node is, which decides how its border and tint are drawn.
pub type Kind {
  /// A container that groups nodes under a title, with a neutral border.
  Group
  /// A container for code that runs in the trusted harness VM.
  TrustedZone
  /// A container for what runs under kernel enforcement, outside the VM.
  JailZone
  /// A process or a service in the harness VM.
  Process
  /// Work that runs in a kernel jail.
  Jailed
  /// Durable storage.
  Store
  /// Something outside Loom, such as the model provider or a person.
  Outside
  /// One stage of a sequence, drawn small.
  Stage
}

/// How a state is coloured: neutral, active in this step, finished in good
/// order, or failed.
pub type Tone {
  Quiet
  Live
  Done
  Fault
}

/// A box on the drawing.
pub type Node {
  Node(
    /// The id that links, pulses and states refer to.
    id: String,
    /// The name drawn in bold, which is the repository's name for the thing.
    title: String,
    /// A second line under the title, or an empty string.
    detail: String,
    /// The short name of the container the box belongs to, such as `A`, when
    /// two boxes share a title. The table under the drawing prefixes it, so
    /// that every row names one actor.
    scope: String,
    kind: Kind,
    /// Where the box sits when the container is wide.
    wide: Rect,
    /// Where the box sits when the container is narrow.
    narrow: Rect,
  )
}

/// A connection between two nodes. A message can travel either way on it.
pub type Link {
  Link(id: String, a: String, b: String)
}

/// The state of one node during one step. A state may hold several lines,
/// separated by newlines.
pub type NodeState {
  NodeState(node: String, text: String, tone: Tone)
}

/// A message in flight on a link during a step.
pub type Pulse {
  Pulse(link: String, from: String, label: String)
}

/// A headline fact for a step, such as who owns the session.
pub type Chip {
  Chip(label: String, value: String)
}

/// Everything the drawing shows at one step.
pub type Frame {
  Frame(
    /// The state of every box.
    states: List(NodeState),
    /// The messages in flight.
    pulses: List(Pulse),
    /// An optional headline fact.
    chip: Option(Chip),
  )
}

/// A figure's drawing: boxes, links and one frame per step.
pub type Diagram {
  Diagram(
    sizes: Sizes,
    nodes: List(Node),
    links: List(Link),
    /// One frame per step, in step order.
    frames: List(Frame),
  )
}

/// Which of the two layouts to compute geometry for.
pub type Layout {
  Wide
  Narrow
}

/// A point in layout units.
pub type Point {
  Point(x: Int, y: Int)
}

/// A node's rectangle in a layout.
pub fn rect_of(node: Node, layout: Layout) -> Rect {
  case layout {
    Wide -> node.wide
    Narrow -> node.narrow
  }
}

/// Whether a rectangle has an area and so is drawn.
pub fn is_drawn(rect: Rect) -> Bool {
  rect.w > 0 && rect.h > 0
}

/// Whether a node is a container instead of a box with a state.
pub fn is_container(node: Node) -> Bool {
  case node.kind {
    Group | TrustedZone | JailZone -> True
    _ -> False
  }
}

/// The nodes that carry a state, which are all but the containers.
pub fn boxes(diagram: Diagram) -> List(Node) {
  list.filter(diagram.nodes, fn(node) { !is_container(node) })
}

/// A node by id.
pub fn find_node(diagram: Diagram, id: String) -> Result(Node, Nil) {
  list.find(diagram.nodes, fn(node) { node.id == id })
}

/// A link by id.
pub fn find_link(diagram: Diagram, id: String) -> Result(Link, Nil) {
  list.find(diagram.links, fn(link) { link.id == id })
}

/// The frame of a step, if the figure has that many.
pub fn frame_at(diagram: Diagram, index: Int) -> Result(Frame, Nil) {
  case list.drop(diagram.frames, index) {
    [frame, ..] if index >= 0 -> Ok(frame)
    _ -> Error(Nil)
  }
}

/// The state a frame gives a node.
pub fn state_of(frame: Frame, node: String) -> Result(NodeState, Nil) {
  list.find(frame.states, fn(state) { state.node == node })
}

/// Builds a frame with no chip.
pub fn frame(states: List(NodeState), pulses: List(Pulse)) -> Frame {
  Frame(states: states, pulses: pulses, chip: option.None)
}

/// The spacing between parallel lines that share a pair of nodes.
const lane_gap = 7

/// Routes a path from rectangle `a` to rectangle `b`.
///
/// When the rectangles overlap vertically the path is a horizontal line
/// through the middle of the overlap. When they overlap horizontally it is a
/// vertical line through the middle of the overlap. Otherwise it leaves `a`
/// sideways and enters `b` from above or below. `lane` shifts the line off
/// the centre so two messages on one link do not draw over each other.
///
/// ## Examples
///
/// ```gleam
/// route(Rect(0, 0, 100, 50), Rect(200, 0, 100, 50), 0)
/// // -> [Point(100, 25), Point(200, 25)]
/// ```
pub fn route(a: Rect, b: Rect, lane: Int) -> List(Point) {
  let shift = lane * lane_gap
  let y_low = int_max(a.y, b.y)
  let y_high = int_min(a.y + a.h, b.y + b.h)
  let x_low = int_max(a.x, b.x)
  let x_high = int_min(a.x + a.w, b.x + b.w)
  case y_low < y_high, x_low < x_high {
    True, _ -> {
      let y = { y_low + y_high } / 2 + shift
      case a.x < b.x {
        True -> [Point(a.x + a.w, y), Point(b.x, y)]
        False -> [Point(a.x, y), Point(b.x + b.w, y)]
      }
    }
    False, True -> {
      let x = { x_low + x_high } / 2 + shift
      case a.y < b.y {
        True -> [Point(x, a.y + a.h), Point(x, b.y)]
        False -> [Point(x, a.y), Point(x, b.y + b.h)]
      }
    }
    False, False -> {
      let y = a.y + a.h / 2 + shift
      let x = b.x + b.w / 2 + shift
      let start_x = case a.x < b.x {
        True -> a.x + a.w
        False -> a.x
      }
      let end_y = case a.y < b.y {
        True -> b.y
        False -> b.y + b.h
      }
      [Point(start_x, y), Point(x, y), Point(x, end_y)]
    }
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

/// The point halfway along the longest segment of a path.
pub fn label_point(points: List(Point)) -> Point {
  let segments = list.zip(points, list.drop(points, 1))
  let longest =
    list.fold(segments, #(Point(0, 0), Point(0, 0), -1), fn(best, segment) {
      let #(p, q) = segment
      let length = abs(q.x - p.x) + abs(q.y - p.y)
      case length > best.2 {
        True -> #(p, q, length)
        False -> best
      }
    })
  let #(p, q, _) = longest
  Point({ p.x + q.x } / 2, { p.y + q.y } / 2)
}

fn abs(n: Int) -> Int {
  case n < 0 {
    True -> 0 - n
    False -> n
  }
}

/// The CSS pixel sizes of the text in a box. The stylesheet uses the same
/// numbers, and `text_height` relies on them.
pub const title_px = 13

pub const body_px = 12

/// The padding inside a box, in pixels, on each side.
pub const padding_px = 8

/// How wide an average character is, as a fraction of the font size
/// expressed in hundredths. Measured in the browser, the sans-serif body text
/// averages 47 to 50, so 52 leaves a little room for another font. Bold text
/// is wider.
const body_width_hundredths = 52

const bold_width_hundredths = 60

/// The height a box needs for its words, in pixels, at a given width. It
/// wraps by character count, so it is an estimate that errs high, and the
/// tests treat it as a limit.
///
/// ## Examples
///
/// ```gleam
/// text_height("Writer", "", ["running"], 200) == 49
/// ```
pub fn text_height(
  title: String,
  detail: String,
  state_lines: List(String),
  width: Int,
) -> Int {
  let inner = width - 2 * padding_px
  let title_lines = wrapped(title, inner, title_px, bold_width_hundredths)
  let detail_lines = case detail {
    "" -> 0
    _ -> wrapped(detail, inner, body_px, body_width_hundredths)
  }
  let state_total =
    list.fold(state_lines, 0, fn(total, line) {
      total + wrapped(line, inner, body_px, body_width_hundredths)
    })
  2 * padding_px + title_lines * 17 + { detail_lines + state_total } * 16
}

/// How many lines a string takes at a width for a font size.
fn wrapped(text: String, width: Int, font_px: Int, hundredths: Int) -> Int {
  let per_line = int_max(1, width * 100 / { font_px * hundredths })
  let words = string.split(text, " ")
  count_lines(words, per_line, 0, 1)
}

fn count_lines(
  words: List(String),
  per_line: Int,
  used: Int,
  lines: Int,
) -> Int {
  case words {
    [] -> lines
    [word, ..rest] -> {
      let length = string.length(word)
      case used == 0 {
        True -> count_lines(rest, per_line, length, lines)
        False ->
          case used + 1 + length <= per_line {
            True -> count_lines(rest, per_line, used + 1 + length, lines)
            False -> count_lines(rest, per_line, length, lines + 1)
          }
      }
    }
  }
}

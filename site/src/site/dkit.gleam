//// Short constructors for writing a diagram as data.
////
//// The figure modules state boxes, links and per-step states hundreds of
//// times, and the record syntax would bury the words. These functions fix
//// the argument order once: a box is an id, a title, a detail, a kind and
//// then its two rectangles.

import gleam/option.{None, Some}
import site/diagram.{
  type Frame, type Kind, type Node, type NodeState, type Pulse, type Rect,
  type Tone, Chip, Frame, Link, Node, NodeState, Pulse, Rect,
}

/// A rectangle.
pub fn r(x: Int, y: Int, w: Int, h: Int) -> Rect {
  Rect(x, y, w, h)
}

/// A box with a state.
pub fn node(
  id: String,
  title: String,
  detail: String,
  kind: Kind,
  wide: Rect,
  narrow: Rect,
) -> Node {
  Node(id, title, detail, "", kind, wide, narrow)
}

/// Names the container a box belongs to, so that the table under the drawing
/// can tell two boxes with the same title apart.
pub fn scoped(node: Node, scope: String) -> Node {
  Node(..node, scope: scope)
}

/// A container. It has a title and no state.
pub fn zone(
  id: String,
  title: String,
  kind: Kind,
  wide: Rect,
  narrow: Rect,
) -> Node {
  Node(id, title, "", "", kind, wide, narrow)
}

/// A link between two boxes.
pub fn link(id: String, a: String, b: String) -> diagram.Link {
  Link(id, a, b)
}

/// The state of a box.
pub fn state(node: String, text: String, tone: Tone) -> NodeState {
  NodeState(node, text, tone)
}

/// A message from one end of a link.
pub fn send(link: String, from: String, label: String) -> Pulse {
  Pulse(link, from, label)
}

/// A frame with no headline fact.
pub fn frame(states: List(NodeState), pulses: List(Pulse)) -> Frame {
  Frame(states: states, pulses: pulses, chip: None)
}

/// A frame with a headline fact.
pub fn with_chip(frame: Frame, label: String, value: String) -> Frame {
  Frame(..frame, chip: Some(Chip(label, value)))
}

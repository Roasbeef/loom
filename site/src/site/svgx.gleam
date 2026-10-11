//// Small helpers for drawing the figures in SVG.
////
//// Each figure is a pure function from a step number to an SVG tree. Shapes
//// carry CSS classes, and the stylesheet decides colour and transitions, so
//// a step change is a class change and the browser animates it. Coordinates
//// are integers in the figure's own viewBox.

import gleam/int
import gleam/list
import lustre/attribute.{type Attribute, attribute}
import lustre/element.{type Element}
import lustre/element/svg

/// The root element. `label` becomes the accessible name of the drawing.
pub fn root(
  width: Int,
  height: Int,
  label: String,
  children: List(Element(msg)),
) -> Element(msg) {
  svg.svg(
    [
      attribute("viewBox", "0 0 " <> int.to_string(width) <> " " <> int.to_string(height)),
      attribute("role", "img"),
      attribute("aria-label", label),
      attribute("preserveAspectRatio", "xMidYMid meet"),
      attribute.class("fig-svg"),
    ],
    children,
  )
}

/// A class attribute made of a base class and the extra classes whose flag
/// is set.
pub fn cls(base: String, extra: List(#(String, Bool))) -> Attribute(msg) {
  let on =
    list.filter_map(extra, fn(pair) {
      case pair.1 {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  attribute.class(join([base, ..on]))
}

fn join(names: List(String)) -> String {
  case names {
    [] -> ""
    [one] -> one
    [first, ..rest] -> first <> " " <> join(rest)
  }
}

fn num(name: String, value: Int) -> Attribute(msg) {
  attribute(name, int.to_string(value))
}

/// A rounded rectangle.
pub fn rect(
  x: Int,
  y: Int,
  width: Int,
  height: Int,
  attrs: List(Attribute(msg)),
) -> Element(msg) {
  svg.rect([
    num("x", x),
    num("y", y),
    num("width", width),
    num("height", height),
    num("rx", 8),
    ..attrs
  ])
}

/// A rectangle with square corners.
pub fn square(
  x: Int,
  y: Int,
  width: Int,
  height: Int,
  attrs: List(Attribute(msg)),
) -> Element(msg) {
  svg.rect([
    num("x", x),
    num("y", y),
    num("width", width),
    num("height", height),
    ..attrs
  ])
}

/// A line segment.
pub fn line(
  x1: Int,
  y1: Int,
  x2: Int,
  y2: Int,
  attrs: List(Attribute(msg)),
) -> Element(msg) {
  svg.line([num("x1", x1), num("y1", y1), num("x2", x2), num("y2", y2), ..attrs])
}

/// A path from a string of SVG path commands.
pub fn path(d: String, attrs: List(Attribute(msg))) -> Element(msg) {
  svg.path([attribute("d", d), ..attrs])
}

/// A circle.
pub fn circle(
  cx: Int,
  cy: Int,
  r: Int,
  attrs: List(Attribute(msg)),
) -> Element(msg) {
  svg.circle([num("cx", cx), num("cy", cy), num("r", r), ..attrs])
}

/// Text anchored at its start. Add the class `mid` or `end` to the
/// attributes to anchor it elsewhere.
pub fn text(
  x: Int,
  y: Int,
  content: String,
  attrs: List(Attribute(msg)),
) -> Element(msg) {
  svg.text([num("x", x), num("y", y), ..attrs], content)
}

/// A group.
pub fn group(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  svg.g(attrs, children)
}

/// A translation expressed as a CSS transform, so that a change animates.
pub fn at(x: Int, y: Int) -> Attribute(msg) {
  attribute.style("transform", "translate(" <> int.to_string(x) <> "px, " <> int.to_string(y) <> "px)")
}

/// A CSS transition delay, in milliseconds.
pub fn delay(milliseconds: Int) -> Attribute(msg) {
  attribute.style("transition-delay", int.to_string(milliseconds) <> "ms")
}

/// An arrowhead marker definition. Referenced by the `arrow` class in CSS
/// through `marker-end: url(#arrow)`.
pub fn defs() -> Element(msg) {
  svg.defs([], [
    svg.marker(
      [
        attribute.id("arrow"),
        attribute("viewBox", "0 0 10 10"),
        attribute("refX", "8"),
        attribute("refY", "5"),
        attribute("markerWidth", "7"),
        attribute("markerHeight", "7"),
        attribute("orient", "auto-start-reverse"),
      ],
      [svg.path([attribute("d", "M 0 1 L 9 5 L 0 9 z"), attribute.class("arrowhead")])],
    ),
  ])
}

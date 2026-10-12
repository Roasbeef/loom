//// The small icons on the figure and replay controls.
////
//// Each is a 14 by 14 SVG drawn with `currentColor`, so it follows the
//// button's text colour in both themes. They are decoration: the button's
//// own words say what it does, so the icons are hidden from assistive
//// technology.

import lustre/attribute.{attribute}
import lustre/element.{type Element}
import lustre/element/svg

/// A chevron pointing left.
pub fn back() -> Element(msg) {
  stroked("M 9 2 L 4 7 L 9 12")
}

/// A chevron pointing right.
pub fn forward() -> Element(msg) {
  stroked("M 5 2 L 10 7 L 5 12")
}

/// A right-pointing triangle.
pub fn play() -> Element(msg) {
  filled("M 3 2 L 12 7 L 3 12 z")
}

/// Two bars.
pub fn pause() -> Element(msg) {
  filled("M 3 2 H 6 V 12 H 3 z M 8 2 H 11 V 12 H 8 z")
}

/// An arrow going round, for starting over.
pub fn restart() -> Element(msg) {
  stroked("M 2.5 7 A 4.5 4.5 0 1 0 4 3.6 M 2 1.5 V 4.5 H 5")
}

fn frame(children: List(Element(msg))) -> Element(msg) {
  svg.svg(
    [
      attribute("viewBox", "0 0 14 14"),
      attribute("width", "14"),
      attribute("height", "14"),
      attribute("aria-hidden", "true"),
      attribute.class("icon"),
    ],
    children,
  )
}

fn stroked(d: String) -> Element(msg) {
  frame([
    svg.path([
      attribute("d", d),
      attribute("fill", "none"),
      attribute("stroke", "currentColor"),
      attribute("stroke-width", "1.8"),
      attribute("stroke-linecap", "round"),
      attribute("stroke-linejoin", "round"),
    ]),
  ])
}

fn filled(d: String) -> Element(msg) {
  frame([svg.path([attribute("d", d), attribute("fill", "currentColor")])])
}

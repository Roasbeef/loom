//// Draws a diagram at a step.
////
//// A drawing is HTML boxes over an SVG that carries the lines. The boxes
//// keep their text at a fixed pixel size while the layout scales, which is
//// what keeps every label legible on a phone: there are two layouts, and a
//// container query in the stylesheet shows the one that fits the width the
//// figure has. Both are rendered; the hidden one costs nothing to look at.
////
//// The drawing is a picture of what the state table beneath it says in words,
//// so the drawing is hidden from assistive technology and the table is not.
////
//// ## Flow
////
//// - `schematic` renders both layouts of the step.
//// - `layout_view` places the containers, the lines and the boxes of one
////   layout.
//// - `lines_view` routes each link and highlights the ones carrying a
////   message.
//// - `states` is the table of every box's state, `wire` the list of messages
////   in flight, and `chip` the headline fact.

import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import lustre/attribute.{type Attribute, attribute, class}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import site/diagram.{
  type Diagram, type Frame, type Kind, type Layout, type Link, type Node,
  type NodeState, type Point, type Pulse, type Rect, type Tone, Done, Fault,
  Group, JailZone, Jailed, Live, Narrow, Outside, Point, Process, Quiet, Stage,
  Store, TrustedZone, Wide,
}

/// Both layouts of a diagram at a step. `index` is the step number, whose
/// parity decides which of two identical animations a highlighted line runs,
/// so that a change of step restarts the animation.
pub fn schematic(diagram: Diagram, index: Int) -> Element(msg) {
  let frame = case diagram.frame_at(diagram, index) {
    Ok(frame) -> frame
    Error(Nil) -> diagram.frame([], [])
  }
  html.div([class("dgm"), attribute("aria-hidden", "true")], [
    layout_view(diagram, frame, index, Wide),
    layout_view(diagram, frame, index, Narrow),
  ])
}

fn layout_view(
  diagram: Diagram,
  frame: Frame,
  index: Int,
  layout: Layout,
) -> Element(msg) {
  let #(width, height, name) = case layout {
    Wide -> #(diagram.sizes.wide_w, diagram.sizes.wide_h, "wide")
    Narrow -> #(diagram.sizes.narrow_w, diagram.sizes.narrow_h, "narrow")
  }
  let drawn =
    list.filter(diagram.nodes, fn(node) {
      diagram.is_drawn(diagram.rect_of(node, layout))
    })
  let containers = list.filter(drawn, diagram.is_container)
  let boxes = list.filter(drawn, fn(node) { !diagram.is_container(node) })
  html.div(
    [
      class("dgm-layout dgm-" <> name),
      attribute.style(
        "aspect-ratio",
        int.to_string(width) <> " / " <> int.to_string(height),
      ),
    ],
    list.flatten([
      list.map(containers, fn(node) {
        container_view(node, layout, width, height)
      }),
      [lines_view(diagram, frame, layout, width, height, index % 2)],
      list.map(boxes, fn(node) { box_view(node, frame, layout, width, height) }),
    ]),
  )
}

fn container_view(
  node: Node,
  layout: Layout,
  width: Int,
  height: Int,
) -> Element(msg) {
  html.div(
    [
      class("dnode dzone kind-" <> kind_name(node.kind)),
      place(diagram.rect_of(node, layout), width, height),
    ],
    [html.span([class("dz-title")], [text(node.title)])],
  )
}

fn box_view(
  node: Node,
  frame: Frame,
  layout: Layout,
  width: Int,
  height: Int,
) -> Element(msg) {
  let state = diagram.state_of(frame, node.id)
  let tone = case state {
    Ok(s) -> s.tone
    Error(Nil) -> Quiet
  }
  html.div(
    [
      class(
        "dnode dbox kind-"
        <> kind_name(node.kind)
        <> " tone-"
        <> tone_name(tone),
      ),
      place(diagram.rect_of(node, layout), width, height),
    ],
    [
      html.div([class("dn-title")], [text(node.title)]),
      case node.detail {
        "" -> element.none()
        detail -> html.div([class("dn-detail")], [text(detail)])
      },
      case state {
        Ok(s) -> html.div([class("dn-state")], state_lines(s.text))
        Error(Nil) -> element.none()
      },
    ],
  )
}

fn state_lines(words: String) -> List(Element(msg)) {
  list.map(string.split(words, "\n"), fn(line) {
    html.div([class("dn-line")], [text(line)])
  })
}

fn lines_view(
  diagram: Diagram,
  frame: Frame,
  layout: Layout,
  width: Int,
  height: Int,
  parity: Int,
) -> Element(msg) {
  let base =
    list.filter_map(diagram.links, fn(link) {
      case link_points(diagram, link, layout, 0) {
        Ok(points) ->
          Ok(
            svg.path([
              class("dl-base"),
              attribute("d", path_data(points)),
              attribute("vector-effect", "non-scaling-stroke"),
            ]),
          )
        Error(Nil) -> Error(Nil)
      }
    })
  svg.svg(
    [
      class("dgm-lines"),
      attribute(
        "viewBox",
        "0 0 " <> int.to_string(width) <> " " <> int.to_string(height),
      ),
      attribute("preserveAspectRatio", "none"),
      attribute("aria-hidden", "true"),
    ],
    list.append(base, pulse_views(diagram, frame, layout, parity)),
  )
}

/// The highlighted path of each message in the step. Two messages on one
/// link are drawn on separate lanes.
fn pulse_views(
  diagram: Diagram,
  frame: Frame,
  layout: Layout,
  parity: Int,
) -> List(Element(msg)) {
  frame.pulses
  |> list.index_map(fn(pulse, i) {
    let lane = lane_for(frame.pulses, pulse, i)
    case diagram.find_link(diagram, pulse.link) {
      Error(Nil) -> []
      Ok(link) ->
        case link_points(diagram, link, layout, lane) {
          Error(Nil) -> []
          Ok(points) -> {
            let ordered = case pulse.from == link.a {
              True -> points
              False -> list.reverse(points)
            }
            [
              svg.path([
                class("dl-live dl-live-" <> int.to_string(parity)),
                attribute("d", path_data(ordered)),
                attribute("vector-effect", "non-scaling-stroke"),
              ]),
              arrowhead(ordered),
            ]
          }
        }
    }
  })
  |> list.flatten
}

/// A small triangle at the end of a path. A marker would be stretched by the
/// non-uniform scaling of the drawing, so the head is a polygon drawn in
/// layout units and kept small enough that the stretch does not show.
fn arrowhead(points: List(Point)) -> Element(msg) {
  case list.reverse(points) {
    [last, previous, ..] -> {
      let dx = last.x - previous.x
      let dy = last.y - previous.y
      let #(a, b) = case int.absolute_value(dx) >= int.absolute_value(dy) {
        True -> {
          let sign = case dx >= 0 {
            True -> 1
            False -> -1
          }
          #(
            Point(last.x - 7 * sign, last.y - 4),
            Point(last.x - 7 * sign, last.y + 4),
          )
        }
        False -> {
          let sign = case dy >= 0 {
            True -> 1
            False -> -1
          }
          #(
            Point(last.x - 4, last.y - 7 * sign),
            Point(last.x + 4, last.y - 7 * sign),
          )
        }
      }
      svg.polygon([
        class("dl-head"),
        attribute(
          "points",
          int.to_string(last.x)
            <> ","
            <> int.to_string(last.y)
            <> " "
            <> int.to_string(a.x)
            <> ","
            <> int.to_string(a.y)
            <> " "
            <> int.to_string(b.x)
            <> ","
            <> int.to_string(b.y),
        ),
      ])
    }
    _ -> element.none()
  }
}

/// Lane -1 or +1 when a link carries two messages, 0 otherwise.
fn lane_for(pulses: List(Pulse), pulse: Pulse, index: Int) -> Int {
  let same = list.filter(pulses, fn(p) { p.link == pulse.link })
  case same {
    [_, _, ..] -> {
      let earlier =
        pulses
        |> list.take(index)
        |> list.filter(fn(p) { p.link == pulse.link })
        |> list.length
      case earlier % 2 {
        0 -> -1
        _ -> 1
      }
    }
    _ -> 0
  }
}

fn link_points(
  diagram: Diagram,
  link: Link,
  layout: Layout,
  lane: Int,
) -> Result(List(Point), Nil) {
  case diagram.find_node(diagram, link.a), diagram.find_node(diagram, link.b) {
    Ok(a), Ok(b) -> {
      let ra = diagram.rect_of(a, layout)
      let rb = diagram.rect_of(b, layout)
      case diagram.is_drawn(ra) && diagram.is_drawn(rb) {
        True -> Ok(diagram.route(ra, rb, lane))
        False -> Error(Nil)
      }
    }
    _, _ -> Error(Nil)
  }
}

fn path_data(points: List(Point)) -> String {
  points
  |> list.index_map(fn(p, i) {
    let command = case i {
      0 -> "M"
      _ -> "L"
    }
    command <> int.to_string(p.x) <> " " <> int.to_string(p.y)
  })
  |> string.join(" ")
}

/// Absolute position as percentages of the layout, so boxes scale with it.
fn place(rect: Rect, width: Int, height: Int) -> Attribute(msg) {
  attribute.styles([
    #("left", percent(rect.x, width)),
    #("top", percent(rect.y, height)),
    #("width", percent(rect.w, width)),
    #("height", percent(rect.h, height)),
  ])
}

/// `part` of `whole` as a percentage with two decimals.
fn percent(part: Int, whole: Int) -> String {
  let hundredths = part * 10_000 / whole
  let fraction = hundredths % 100
  let padded = case fraction < 10 {
    True -> "0" <> int.to_string(fraction)
    False -> int.to_string(fraction)
  }
  int.to_string(hundredths / 100) <> "." <> padded <> "%"
}

// THE TABLE UNDER THE DRAWING --------------------------------------------------

/// The state of every box at a step, as a table: one row per actor. This is
/// the text equivalent of the drawing and the thing a reader can quote.
pub fn states(diagram: Diagram, index: Int, caption: String) -> Element(msg) {
  let rows = case diagram.frame_at(diagram, index) {
    Error(Nil) -> []
    Ok(frame) ->
      list.filter_map(diagram.boxes(diagram), fn(node) {
        case diagram.state_of(frame, node.id) {
          Ok(state) -> Ok(state_row(node, state))
          Error(Nil) -> Error(Nil)
        }
      })
  }
  html.table([class("dgm-states")], [
    html.caption([class("visually-hidden")], [text(caption)]),
    html.thead([class("visually-hidden")], [
      html.tr([], [
        html.th([attribute("scope", "col")], [text("Actor")]),
        html.th([attribute("scope", "col")], [text("State")]),
      ]),
    ]),
    html.tbody([], rows),
  ])
}

fn state_row(node: Node, state: NodeState) -> Element(msg) {
  html.tr([class("tone-" <> tone_name(state.tone))], [
    html.th([attribute("scope", "row")], [text(label_of(node))]),
    html.td([], [
      html.span([class("sdot"), attribute("aria-hidden", "true")], []),
      text(string.replace(state.text, "\n", "; ")),
    ]),
  ])
}

/// The messages in flight at a step, as a list of "from to to: label".
pub fn wire(diagram: Diagram, index: Int) -> Element(msg) {
  case diagram.frame_at(diagram, index) {
    Error(Nil) -> element.none()
    Ok(frame) ->
      case frame.pulses {
        [] -> element.none()
        pulses ->
          html.p(
            [class("dgm-wire")],
            list.flatten([
              [html.span([class("dgm-wire-label")], [text("On the wire")])],
              list.map(pulses, fn(pulse) {
                let #(from, to) = endpoints(diagram, pulse)
                html.span([class("dgm-msg")], [
                  text(from <> " to " <> to <> ": "),
                  html.code([], [text(pulse.label)]),
                ])
              }),
            ]),
          )
      }
  }
}

/// The headline fact of a step, if it has one.
pub fn chip(diagram: Diagram, index: Int) -> Element(msg) {
  case diagram.frame_at(diagram, index) {
    Ok(diagram.Frame(chip: Some(chip), ..)) ->
      html.p([class("dgm-chip")], [
        html.span([class("dgm-chip-label")], [text(chip.label)]),
        html.strong([], [text(chip.value)]),
      ])
    _ -> element.none()
  }
}

/// The name of a box in the table: its scope, then its title.
fn label_of(node: Node) -> String {
  case node.scope {
    "" -> node.title
    scope -> scope <> ": " <> node.title
  }
}

fn endpoints(diagram: Diagram, pulse: Pulse) -> #(String, String) {
  let title = fn(id) {
    case diagram.find_node(diagram, id) {
      Ok(node) -> label_of(node)
      Error(Nil) -> id
    }
  }
  case diagram.find_link(diagram, pulse.link) {
    Ok(link) ->
      case pulse.from == link.a {
        True -> #(title(link.a), title(link.b))
        False -> #(title(link.b), title(link.a))
      }
    Error(Nil) -> #(pulse.from, "?")
  }
}

// NAMES -----------------------------------------------------------------------

fn tone_name(tone: Tone) -> String {
  case tone {
    Quiet -> "quiet"
    Live -> "live"
    Done -> "done"
    Fault -> "fault"
  }
}

fn kind_name(kind: Kind) -> String {
  case kind {
    Group -> "group"
    TrustedZone -> "trusted-zone"
    JailZone -> "jail-zone"
    Process -> "process"
    Jailed -> "jailed"
    Store -> "store"
    Outside -> "outside"
    Stage -> "stage"
  }
}

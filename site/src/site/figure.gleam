//// The step-through figure.
////
//// A figure is a drawing plus a list of steps. Each step has a name, a
//// one-sentence caption that sits under the drawing, and a block of text
//// that explains it. On the landing page the blocks form a column beside a
//// sticky panel, and the scroll position picks the step. The same panel has
//// explicit controls, so the figure works without scrolling, and it can be
//// embedded in a documentation page, where the current step's block follows
//// the panel.
////
//// This module owns the layout and the controls. The drawings and the
//// wording of each step live in `site/fig_*`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{type Attribute, attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/code
import site/diagram.{type Diagram}
import site/diagram_view
import site/icons
import site/inline
import site/msg.{type FigureId, type Msg}

/// A line of code or output shown in a step's text block.
pub type Sample {
  Sample(title: String, text: String)
}

/// One step of a figure.
pub type Step {
  Step(
    /// A short name for the step, used on the progress dots.
    label: String,
    /// Extra words for the step's kicker, or an empty string.
    tag: String,
    /// One sentence that describes what the drawing shows.
    caption: String,
    /// The heading of the step's text block.
    heading: String,
    /// The paragraphs of the text block. Inline marks are allowed.
    body: List(String),
    /// Facts that hold after this step, as label and value pairs.
    state: List(#(String, String)),
    /// An optional code sample.
    sample: Option(Sample),
    /// What happens if something fails at this step, when the docs say.
    failure: Option(String),
  )
}

/// A figure's content.
pub type Spec {
  Spec(
    id: FigureId,
    /// The name of the figure, for the accessible label.
    title: String,
    /// The boxes, links and per-step states of the drawing.
    diagram: Diagram,
    steps: List(Step),
  )
}

/// How many steps a figure has.
pub fn count(spec: Spec) -> Int {
  list.length(spec.steps)
}

fn step_at(spec: Spec, index: Int) -> Step {
  case list.drop(spec.steps, index) {
    [step, ..] -> step
    [] -> panic as "figure step out of range"
  }
}

/// The landing-page layout: text blocks beside a sticky panel.
pub fn scrolly(
  spec: Spec,
  active: Int,
  playing: Bool,
  copied: Option(String),
) -> Element(Msg) {
  html.div(
    [
      attribute.class("scrolly"),
      attribute("data-fig", msg.figure_key(spec.id)),
    ],
    [
      html.div(
        [attribute.class("scrolly-text")],
        list.index_map(spec.steps, fn(step, index) {
          block(spec.id, step, index, count(spec), index == active, copied)
        }),
      ),
      panel(spec, active, playing),
    ],
  )
}

/// The documentation layout: the panel, then the current step's block.
pub fn embedded(
  spec: Spec,
  active: Int,
  playing: Bool,
  copied: Option(String),
) -> Element(Msg) {
  html.div([attribute.class("embedded")], [
    panel(spec, active, playing),
    block(spec.id, step_at(spec, active), active, count(spec), True, copied),
  ])
}

fn panel(spec: Spec, active: Int, playing: Bool) -> Element(Msg) {
  let total = count(spec)
  let step = step_at(spec, active)
  html.figure(
    [
      attribute.class("panel"),
      attribute("data-fig-panel", msg.figure_key(spec.id)),
      attribute(
        "aria-label",
        spec.title
          <> ", step "
          <> int.to_string(active + 1)
          <> " of "
          <> int.to_string(total),
      ),
      attribute.tabindex(0),
      event.on_keydown(fn(key) { key_message(spec.id, active, total, key) }),
    ],
    [
      html.div([attribute.class("panel-stage")], [
        diagram_view.chip(spec.diagram, active),
        diagram_view.schematic(spec.diagram, active),
      ]),
      html.figcaption(
        [attribute.class("panel-caption"), attribute("aria-live", "polite")],
        [
          html.span([attribute.class("panel-count")], [
            element.text(
              int.to_string(active + 1) <> " / " <> int.to_string(total),
            ),
          ]),
          html.strong([], [element.text(step.label <> ". ")]),
          ..inline.render(step.caption)
        ],
      ),
      controls(spec, active, playing),
      html.div([attribute.class("panel-states")], [
        diagram_view.states(
          spec.diagram,
          active,
          "State of each part after step " <> int.to_string(active + 1),
        ),
        diagram_view.wire(spec.diagram, active),
      ]),
    ],
  )
}

fn key_message(id: FigureId, active: Int, total: Int, key: String) -> Msg {
  case key {
    "ArrowRight" | "ArrowDown" ->
      msg.FigureGo(id, int.min(active + 1, total - 1))
    "ArrowLeft" | "ArrowUp" -> msg.FigureGo(id, int.max(active - 1, 0))
    "Home" -> msg.FigureGo(id, 0)
    "End" -> msg.FigureGo(id, total - 1)
    _ -> msg.Ignore
  }
}

fn controls(spec: Spec, active: Int, playing: Bool) -> Element(Msg) {
  let total = count(spec)
  let last = total - 1
  html.div([attribute.class("controls")], [
    html.button(
      [
        attribute.class("btn"),
        attribute.type_("button"),
        attribute.disabled(active == 0),
        event.on_click(msg.FigureGo(spec.id, active - 1)),
      ],
      [icons.back(), element.text("Back")],
    ),
    html.button(
      [
        attribute.class("btn btn-play"),
        attribute.type_("button"),
        attribute("aria-pressed", case playing {
          True -> "true"
          False -> "false"
        }),
        event.on_click(case playing {
          True -> msg.FigureStop
          False -> msg.FigurePlay(spec.id)
        }),
      ],
      case playing {
        True -> [icons.pause(), element.text("Pause")]
        False -> [
          icons.play(),
          element.text(case active == last {
            True -> "Replay"
            False -> "Play"
          }),
        ]
      },
    ),
    html.button(
      [
        attribute.class("btn"),
        attribute.type_("button"),
        attribute.disabled(active == last),
        event.on_click(msg.FigureGo(spec.id, active + 1)),
      ],
      [element.text("Next"), icons.forward()],
    ),
    html.ol(
      [attribute.class("dots"), attribute("aria-label", "Steps")],
      list.index_map(spec.steps, fn(step, index) {
        html.li([], [
          html.button(
            [
              attribute.class(case index == active {
                True -> "dot is-active"
                False -> "dot"
              }),
              attribute.type_("button"),
              attribute(
                "aria-label",
                "Step " <> int.to_string(index + 1) <> ": " <> step.label,
              ),
              attribute("title", step.label),
              event.on_click(msg.FigureGo(spec.id, index)),
              ..current(index == active)
            ],
            [],
          ),
        ])
      }),
    ),
  ])
}

fn current(is_current: Bool) -> List(Attribute(Msg)) {
  case is_current {
    True -> [attribute("aria-current", "step")]
    False -> []
  }
}

/// One step's text.
fn block(
  id: FigureId,
  step: Step,
  index: Int,
  total: Int,
  is_active: Bool,
  copied: Option(String),
) -> Element(Msg) {
  html.article(
    [
      attribute.class(case is_active {
        True -> "step is-active"
        False -> "step"
      }),
      attribute("data-step", int.to_string(index)),
      attribute.id(msg.figure_key(id) <> "-step-" <> int.to_string(index)),
    ],
    [
      html.p([attribute.class("kicker")], [
        element.text(
          "Step "
          <> int.to_string(index + 1)
          <> " of "
          <> int.to_string(total)
          <> case step.tag {
            "" -> ""
            tag -> " · " <> tag
          },
        ),
      ]),
      html.h3([], [element.text(step.heading)]),
      ..list.flatten([
        list.map(step.body, inline.paragraph),
        sample(id, index, step.sample, copied),
        state(step.state),
        failure(step.failure),
        [jump(id, index, is_active)],
      ])
    ],
  )
}

fn jump(id: FigureId, index: Int, is_active: Bool) -> Element(Msg) {
  case is_active {
    True -> element.none()
    False ->
      html.button(
        [
          attribute.class("show-step"),
          attribute.type_("button"),
          event.on_click(msg.FigureGo(id, index)),
        ],
        [element.text("Show this step in the figure")],
      )
  }
}

fn sample(
  id: FigureId,
  index: Int,
  sample: Option(Sample),
  copied: Option(String),
) -> List(Element(Msg)) {
  case sample {
    None -> []
    Some(Sample(title, text)) -> [
      html.div([attribute.class("sample")], [
        html.p([attribute.class("sample-title")], [element.text(title)]),
        code.view(
          msg.figure_key(id) <> "-sample-" <> int.to_string(index),
          sample_language(text),
          text,
          copied,
        ),
      ]),
    ]
  }
}

/// The language a sample is coloured as: Gleam when it starts with an
/// import, a shell command when it starts with a known command, and plain
/// text otherwise.
fn sample_language(text: String) -> String {
  case string.starts_with(text, "import ") {
    True -> "gleam"
    False ->
      case string.starts_with(text, "loom ") {
        True -> "sh"
        False -> ""
      }
  }
}

fn state(rows: List(#(String, String))) -> List(Element(Msg)) {
  case rows {
    [] -> []
    _ -> [
      html.dl(
        [attribute.class("state")],
        list.flat_map(rows, fn(row) {
          [
            html.dt([], inline.render(row.0)),
            html.dd([], inline.render(row.1)),
          ]
        }),
      ),
    ]
  }
}

fn failure(text: Option(String)) -> List(Element(Msg)) {
  case text {
    None -> []
    Some(text) -> [
      html.p([attribute.class("failure")], [
        html.strong([], [element.text("If it fails here. ")]),
        ..inline.render(text)
      ]),
    ]
  }
}

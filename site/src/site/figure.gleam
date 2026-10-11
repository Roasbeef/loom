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
import lustre/attribute.{type Attribute, attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
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
  drawing: Element(Msg),
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
          block(spec.id, step, index, count(spec), index == active)
        }),
      ),
      panel(spec, active, playing, drawing),
    ],
  )
}

/// The documentation layout: the panel, then the current step's block.
pub fn embedded(
  spec: Spec,
  active: Int,
  playing: Bool,
  drawing: Element(Msg),
) -> Element(Msg) {
  html.div([attribute.class("embedded")], [
    panel(spec, active, playing, drawing),
    block(spec.id, step_at(spec, active), active, count(spec), True),
  ])
}

fn panel(
  spec: Spec,
  active: Int,
  playing: Bool,
  drawing: Element(Msg),
) -> Element(Msg) {
  let total = count(spec)
  let step = step_at(spec, active)
  html.figure(
    [
      attribute.class("panel"),
      attribute("data-fig-panel", msg.figure_key(spec.id)),
      attribute("aria-label", spec.title <> ", step " <> int.to_string(active + 1) <> " of " <> int.to_string(total)),
      attribute.tabindex(0),
      event.on_keydown(fn(key) { key_message(spec.id, active, total, key) }),
    ],
    [
      html.div([attribute.class("panel-stage")], [drawing]),
      html.figcaption([attribute.class("panel-caption"), attribute("aria-live", "polite")], [
        html.span([attribute.class("panel-count")], [
          element.text(int.to_string(active + 1) <> " / " <> int.to_string(total)),
        ]),
        html.strong([], [element.text(step.label <> ". ")]),
        ..inline.render(step.caption)
      ]),
      controls(spec, active, playing),
    ],
  )
}

fn key_message(id: FigureId, active: Int, total: Int, key: String) -> Msg {
  case key {
    "ArrowRight" | "ArrowDown" -> msg.FigureGo(id, int.min(active + 1, total - 1))
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
        attribute("aria-label", "Previous step"),
        attribute.disabled(active == 0),
        event.on_click(msg.FigureGo(spec.id, active - 1)),
      ],
      [chevron(Left), element.text("Back")],
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
        True -> [pause_icon(), element.text("Pause")]
        False -> [play_icon(), element.text(case active == last {
          True -> "Replay"
          False -> "Play"
        })]
      },
    ),
    html.button(
      [
        attribute.class("btn"),
        attribute.type_("button"),
        attribute("aria-label", "Next step"),
        attribute.disabled(active == last),
        event.on_click(msg.FigureGo(spec.id, active + 1)),
      ],
      [element.text("Next"), chevron(Right)],
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
              attribute("aria-label", "Step " <> int.to_string(index + 1) <> ": " <> step.label),
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
        sample(step.sample),
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

fn sample(sample: Option(Sample)) -> List(Element(Msg)) {
  case sample {
    None -> []
    Some(Sample(title, text)) -> [
      html.figure([attribute.class("sample")], [
        html.figcaption([], [element.text(title)]),
        html.pre([], [html.code([], [element.text(text)])]),
      ]),
    ]
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

type Direction {
  Left
  Right
}

fn chevron(direction: Direction) -> Element(Msg) {
  let d = case direction {
    Left -> "M 9 2 L 4 7 L 9 12"
    Right -> "M 5 2 L 10 7 L 5 12"
  }
  svg.svg(
    [
      attribute("viewBox", "0 0 14 14"),
      attribute("width", "14"),
      attribute("height", "14"),
      attribute("aria-hidden", "true"),
      attribute.class("icon"),
    ],
    [svg.path([attribute("d", d), attribute("fill", "none"), attribute("stroke", "currentColor"), attribute("stroke-width", "1.8"), attribute("stroke-linecap", "round"), attribute("stroke-linejoin", "round")])],
  )
}

fn play_icon() -> Element(Msg) {
  svg.svg(
    [
      attribute("viewBox", "0 0 14 14"),
      attribute("width", "14"),
      attribute("height", "14"),
      attribute("aria-hidden", "true"),
      attribute.class("icon"),
    ],
    [svg.path([attribute("d", "M 3 2 L 12 7 L 3 12 z"), attribute("fill", "currentColor")])],
  )
}

fn pause_icon() -> Element(Msg) {
  svg.svg(
    [
      attribute("viewBox", "0 0 14 14"),
      attribute("width", "14"),
      attribute("height", "14"),
      attribute("aria-hidden", "true"),
      attribute.class("icon"),
    ],
    [
      svg.rect([attribute("x", "3"), attribute("y", "2"), attribute("width", "3"), attribute("height", "10"), attribute("fill", "currentColor")]),
      svg.rect([attribute("x", "8"), attribute("y", "2"), attribute("width", "3"), attribute("height", "10"), attribute("fill", "currentColor")]),
    ],
  )
}

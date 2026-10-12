//// The landing page's replay section: a terminal that plays a script, the
//// explanation of the step it is on, and the controls.
////
//// The terminal is a recording, and it says so in three places: the REPLAY
//// label in its title bar, the line under it, and the paragraph above it.
//// Playback stops at the approval dialog and waits for the visitor, whose
//// answer changes the steps after it (`site/replay`).
////
//// Everything here works from the keyboard. The buttons are ordinary
//// buttons, the left and right arrow keys step while focus is in the
//// terminal or the controls, the narration is a polite live region, and the
//// dialog's three choices are buttons that nothing preselects.
////
//// ## Flow
////
//// - `view` is the whole section.
//// - `terminal` draws the window: transcript, the dialog when playback is
////   waiting, the second shell for the move, and the prompt box.
//// - `narration` explains the current step and links into the figures.
//// - `controls` is Back, Play, Next, Restart and one chip per step.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute.{attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/highlight
import site/icons
import site/inline
import site/model.{type Model}
import site/msg.{type Msg, AllowOnce, AllowSession, Deny}
import site/replay.{
  type Line, type Step, AgentLine, CodeBlock, NoteLine, OutLine, ShellLine,
  ToolLine, UserLine, WarnLine,
}

/// The section.
pub fn view(model: Model) -> Element(Msg) {
  html.section([attribute.class("story replay"), attribute.id("replay")], [
    html.div([attribute.class("story-head")], [
      html.p([attribute.class("kicker")], [
        element.text("1. A recorded session"),
      ]),
      html.h2([], [
        element.text("One session, from a prompt to a move between machines"),
      ]),
      html.p([], [
        element.text(
          "This is a recording of the terminal client, played from a script. Nothing in it runs, and the project, the file names and the counts are examples. Press Play or step through it. When the approval dialog appears, playback stops until you answer, and your answer changes the steps after it. The dialog's wording is simplified.",
        ),
      ]),
    ]),
    html.div(
      [
        attribute.class("replay-grid"),
        event.on_keydown(fn(key) { key_message(model.replay.index, key) }),
      ],
      [
        terminal(model),
        html.div([attribute.class("replay-side")], [
          narration(model),
          controls(model),
        ]),
      ],
    ),
  ])
}

/// The arrow keys step the replay while focus is anywhere in it. Other keys
/// are left to the buttons and the page.
fn key_message(index: Int, key: String) -> Msg {
  case key {
    "ArrowRight" -> msg.ReplayGo(index + 1)
    "ArrowLeft" -> msg.ReplayGo(index - 1)
    _ -> msg.Ignore
  }
}

// THE TERMINAL ----------------------------------------------------------------

fn terminal(model: Model) -> Element(Msg) {
  let current = model.replay
  let lines = replay.lines(current.index, current.decision)
  let transcript = list.filter(lines, fn(line) { !is_shell(line) })
  let shell = list.filter(lines, is_shell)
  html.div(
    [
      attribute.class("term"),
      attribute("role", "group"),
      attribute(
        "aria-label",
        "Recorded terminal session, step "
          <> int.to_string(current.index + 1)
          <> " of "
          <> int.to_string(replay.last() + 1),
      ),
    ],
    [
      html.div([attribute.class("term-bar")], [
        html.span([attribute.class("term-title")], [
          element.text("session "),
          html.strong([], [element.text("rename-demo")]),
          element.text(" on main"),
        ]),
        html.span([attribute.class("term-tag")], [element.text("REPLAY")]),
      ]),
      html.div([attribute.class("term-body")], [
        html.div([attribute.class("box tx")], [
          html.span([attribute.class("box-title")], [
            element.text("transcript / main"),
          ]),
          html.div([attribute.class("tx-scroll")], [
            html.div(
              [attribute.class("tx-lines")],
              list.map(transcript, line_view),
            ),
          ]),
        ]),
        case replay.waiting(current.index, current.decision) {
          True -> dialog()
          False -> element.none()
        },
        case shell {
          [] -> element.none()
          _ -> shell_box(shell)
        },
        html.div([attribute.class("box prompt")], [
          html.span([attribute.class("box-title")], [
            element.text("prompt, / for commands"),
          ]),
          html.span(
            [attribute.class("cursor"), attribute("aria-hidden", "true")],
            [],
          ),
        ]),
      ]),
      html.div([attribute.class("term-status")], [
        html.span([], [element.text("orchestrator alpha, workspace box:proj")]),
        html.span([], [element.text("recording, example data")]),
      ]),
    ],
  )
}

fn is_shell(line: Line) -> Bool {
  case line {
    ShellLine(..) -> True
    _ -> False
  }
}

fn line_view(line: Line) -> Element(Msg) {
  case line {
    UserLine(text) ->
      html.div([attribute.class("ln ln-user")], [
        html.span([attribute.class("who")], [element.text("You")]),
        html.div([], [element.text(text)]),
      ])
    AgentLine(text) ->
      html.div([attribute.class("ln ln-agent")], [
        html.span([attribute.class("who")], [element.text("Agent")]),
        html.div([], [element.text(text)]),
      ])
    ToolLine(tool, args) ->
      html.div([attribute.class("ln ln-tool")], [
        html.span([attribute.class("tool")], [element.text(tool)]),
        html.span([attribute.class("args")], [element.text(args)]),
      ])
    OutLine(text, delay) ->
      html.div([attribute.class("ln ln-out late"), delay_style(delay)], [
        element.text(text),
      ])
    CodeBlock(source) ->
      html.pre([attribute.class("ln ln-code")], [
        html.code(
          [],
          list.map(string.split(source, "\n"), fn(source_line) {
            html.span(
              [attribute.class("code-line")],
              list.map(highlight.line("gleam", source_line), token),
            )
          }),
        ),
      ])
    NoteLine(text, delay) ->
      html.div([attribute.class("ln ln-note late"), delay_style(delay)], [
        element.text(text),
      ])
    WarnLine(text, delay) ->
      html.div([attribute.class("ln ln-warn late"), delay_style(delay)], [
        element.text(text),
      ])
    ShellLine(text, _) ->
      html.div([attribute.class("ln ln-note")], [element.text(text)])
  }
}

fn delay_style(milliseconds: Int) -> attribute.Attribute(Msg) {
  attribute.style("animation-delay", int.to_string(milliseconds) <> "ms")
}

fn token(item: highlight.Token) -> Element(Msg) {
  case item.kind {
    highlight.Plain -> element.text(item.text)
    highlight.Comment ->
      html.span([attribute.class("t-comment")], [element.text(item.text)])
    highlight.Str ->
      html.span([attribute.class("t-str")], [element.text(item.text)])
    highlight.Keyword ->
      html.span([attribute.class("t-kw")], [element.text(item.text)])
    highlight.Prompt ->
      html.span([attribute.class("t-prompt")], [element.text(item.text)])
    highlight.Key ->
      html.span([attribute.class("t-key")], [element.text(item.text)])
    highlight.Header ->
      html.span([attribute.class("t-header")], [element.text(item.text)])
  }
}

/// A second shell, where the move is started. The move is not part of the
/// session's transcript, so it is not drawn there.
fn shell_box(lines: List(Line)) -> Element(Msg) {
  html.div([attribute.class("box shell late")], [
    html.span([attribute.class("box-title")], [element.text("another terminal")]),
    html.div([attribute.class("tx-lines")], list.map(lines, line_view)),
  ])
}

/// The approval dialog. Nothing in it is selected when it opens, so a stray
/// Enter cannot answer it, which is how the real terminal behaves.
fn dialog() -> Element(Msg) {
  html.div(
    [
      attribute.class("dialog"),
      attribute("role", "group"),
      attribute("aria-labelledby", "replay-dialog-title"),
    ],
    [
      html.div(
        [attribute.class("dialog-title"), attribute.id("replay-dialog-title")],
        [element.text("Approval needed")],
      ),
      html.dl([attribute.class("dialog-facts")], [
        html.dt([], [element.text("Strand")]),
        html.dd([], [element.text("main")]),
        html.dt([], [element.text("Action")]),
        html.dd([], [html.code([], [element.text("bash: make test")])]),
        html.dt([], [element.text("Wants")]),
        html.dd([], [
          element.text("write access to "),
          html.code([], [element.text("/home/dev/.cache/fixtures")]),
        ]),
      ]),
      html.div([attribute.class("dialog-actions")], [
        decision("Allow once", AllowOnce),
        decision("Allow for session", AllowSession),
        decision("Deny", Deny),
      ]),
      html.p([attribute.class("dialog-hint")], [
        element.text("Nothing is selected until you choose."),
      ]),
    ],
  )
}

fn decision(label: String, answer: msg.Decision) -> Element(Msg) {
  html.button(
    [
      attribute.class("btn btn-decision"),
      attribute.type_("button"),
      event.on_click(msg.ReplayDecide(answer)),
    ],
    [element.text(label)],
  )
}

// THE EXPLANATION --------------------------------------------------------------

fn narration(model: Model) -> Element(Msg) {
  let current = model.replay
  case replay.step_at(current.index) {
    None -> element.none()
    Some(step) ->
      html.div(
        [attribute.class("narration"), attribute("aria-live", "polite")],
        [
          html.p([attribute.class("kicker")], [
            element.text(
              "Step "
              <> int.to_string(current.index + 1)
              <> " of "
              <> int.to_string(replay.last() + 1)
              <> ", "
              <> step.chip,
            ),
          ]),
          html.h3([], [element.text(step.title)]),
          inline.paragraph(step.body(current.decision)),
          case replay.waiting(current.index, current.decision) {
            True ->
              html.p([attribute.class("waiting")], [
                element.text(
                  "Playback is stopped. Choose an answer in the dialog.",
                ),
              ])
            False -> element.none()
          },
          underneath(step),
        ],
      )
  }
}

fn underneath(step: Step) -> Element(Msg) {
  case step.underneath {
    None -> element.none()
    Some(link) ->
      html.button(
        [
          attribute.class("show-step"),
          attribute.type_("button"),
          event.on_click(msg.ShowFigure(link.figure, link.step)),
        ],
        [element.text(link.label)],
      )
  }
}

// THE CONTROLS -----------------------------------------------------------------

fn controls(model: Model) -> Element(Msg) {
  let current = model.replay
  let waiting = replay.waiting(current.index, current.decision)
  let furthest = replay.furthest(current.decision)
  html.div([attribute.class("replay-controls")], [
    html.div([attribute.class("controls")], [
      html.button(
        [
          attribute.class("btn"),
          attribute.type_("button"),
          attribute.disabled(current.index == 0),
          event.on_click(msg.ReplayGo(current.index - 1)),
        ],
        [icons.back(), element.text("Back")],
      ),
      play_button(current.playing, current.index, waiting),
      html.button(
        [
          attribute.class("btn"),
          attribute.type_("button"),
          attribute.disabled(current.index >= furthest),
          event.on_click(msg.ReplayGo(current.index + 1)),
        ],
        [element.text("Next"), icons.forward()],
      ),
      html.button(
        [
          attribute.class("btn"),
          attribute.type_("button"),
          event.on_click(msg.ReplayRestart),
        ],
        [icons.restart(), element.text("Restart")],
      ),
    ]),
    html.ol(
      [attribute.class("chips"), attribute("aria-label", "Replay steps")],
      list.index_map(replay.steps(), fn(step, index) {
        html.li([], [
          html.button(
            [
              attribute.class(case index == current.index {
                True -> "chip is-current"
                False ->
                  case index < current.index {
                    True -> "chip is-past"
                    False -> "chip"
                  }
              }),
              attribute.type_("button"),
              attribute.disabled(index > furthest),
              event.on_click(msg.ReplayGo(index)),
              ..case index == current.index {
                True -> [attribute("aria-current", "step")]
                False -> []
              }
            ],
            [
              html.span([attribute.class("chip-n")], [
                element.text(int.to_string(index + 1)),
              ]),
              element.text(step.chip),
            ],
          ),
        ])
      }),
    ),
  ])
}

fn play_button(playing: Bool, index: Int, waiting: Bool) -> Element(Msg) {
  let at_end = index >= replay.last()
  html.button(
    [
      attribute.class("btn btn-play"),
      attribute.type_("button"),
      attribute.disabled(waiting),
      attribute("aria-pressed", case playing {
        True -> "true"
        False -> "false"
      }),
      event.on_click(case playing {
        True -> msg.ReplayPause
        False -> msg.ReplayPlay
      }),
    ],
    case playing {
      True -> [icons.pause(), element.text("Pause")]
      False -> [
        icons.play(),
        element.text(case at_end {
          True -> "Replay"
          False -> "Play"
        }),
      ]
    },
  )
}

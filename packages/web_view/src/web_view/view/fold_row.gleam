//// The rows inside a turn's fold, and the one shape they share: a single line
//// that says what happened, and a body the reader opens from that line.
////
//// A turn's work is a column of steps, each a tool call, a block of
//// reasoning, or the memory context the daemon attached. Each reads as one
//// line (`✓ Edit calc.py +3 −1`, `Reasoning · 4s`, `Memory · 4 lines`) with
//// one chevron, and what lies behind the line (the program, the result, the
//// whole reasoning) is drawn in the same patch and shown only when the reader
//// opens it. The words are `session_view/step_words`: the table that turns a
//// tool's name and arguments into a verb, a subject and the lines an edit
//// changed, shared with the terminal. This module decides how those words are
//// laid out and nothing about what they say.
////
//// The chevron and the open state are `<loom-expand>`'s (`packages/web_client`):
//// the element's one button wraps the row's line, which the server draws in a
//// child marked `slot="head"`, and shows the child marked `slot="body"` once
//// pressed. The browser owns the state, so opening a row costs no message and
//// works on an observer's page, and the server never renders which rows are
//// open. A row with nothing behind it draws no element at all, only its line,
//// so a chevron always means there is more to read.
////
//// Every word of a subject is session text: a path or command the model
//// wrote, a purpose it gave a sub-agent. Each is a text node. The class a
//// subject carries is chosen from `step_words.Subject`, a closed type, and
//// never from the text.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/step_words.{type Words}
import session_view/transcript_line.{type Line}
import session_view/turns

/// One transcript line, drawn once and kept while the line is unchanged.
///
/// The memo's one dependency is the line, so a capture that leaves a line as
/// it was reuses the element it drew and parses its Markdown no more
/// (`view/lane` says why the memos are the leaves).
///
/// ## Examples
///
/// ```gleam
/// // fold_row.line_row(line, fn(line) { html.text(line.text) })
/// ```
pub fn line_row(
  line: Line,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  element.memo([element.ref(line)], fn() { draw(line) })
}

/// One tool call as a row: its state, its words, and its detail behind them.
///
/// The state is a glyph in a colour, and the word for it stays in the row for
/// assistive technology. `body` is what the reader opens; with none, the row
/// is its line alone.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.step(turns.Done, step_words.of_call(call), [program_rows])
/// ```
pub fn step(
  standing: turns.Standing,
  words: Words,
  body: List(Element(message)),
) -> Element(message) {
  let head = [
    html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
      html.text(glyph(standing)),
    ]),
    ..spoken(words)
  ]
  let state =
    html.span([attribute.class("sr-only")], [html.text(state(standing))])
  openable(
    [attribute.class("step"), standing_class(standing)],
    list.append(head, [state]),
    body,
  )
}

/// The memory context as a row: `Memory · 4 lines`, with the message behind it.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.memory(step_words.memory(4), [message_rows])
/// ```
pub fn memory(words: Words, body: List(Element(message))) -> Element(message) {
  openable(
    [attribute.class("step"), attribute.class("memory")],
    spoken(words),
    body,
  )
}

/// A reasoning block as a row: `Reasoning · 4s`, with the reasoning behind
/// it. The time is the response's, from the records, and is left out when
/// they give none.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.reasoning(Some(4000), [thought_rows])
/// ```
pub fn reasoning(
  took_ms: Option(Int),
  body: List(Element(message)),
) -> Element(message) {
  openable(
    [attribute.class("step"), attribute.class("thought")],
    spoken(step_words.reasoning(took_ms)),
    body,
  )
}

/// A row whose line is the report's first line and whose body is the rest, for
/// a result that runs longer than its first line: the line is what a reader
/// scans and the body is what they open. The line is given as elements (a
/// Markdown line from `markdown_view.line`), so it keeps its bold and code.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.reading([html.text("README draft ready")], [report_body])
/// ```
pub fn reading(
  line: List(Element(message)),
  body: List(Element(message)),
) -> Element(message) {
  openable(
    [attribute.class("step"), attribute.class("reading")],
    [html.span([attribute.class("subject")], line)],
    body,
  )
}

/// The open body of a failed step: one plain sentence in the danger colour that
/// says what was refused, and under it the engine's own text in the code face.
///
/// The sentence is `step_words.failure_sentence`, so it names the step and not
/// the tool. The engine's text is the model's to read, so it is drawn as it was
/// written except that a backtick pair is a code span and no backtick is on
/// screen. An odd number of backticks leaves the text exactly as written.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.failure("The edit was rejected.", "invalid arguments: `from` is required")
/// ```
pub fn failure(sentence: String, engine: String) -> Element(message) {
  html.div([attribute.class("step-error")], [
    html.p([attribute.class("step-error-sentence")], [html.text(sentence)]),
    html.pre([attribute.class("step-error-engine")], ticked(engine)),
  ])
}

// Text with its backtick pairs as code spans. The pieces between backticks
// alternate text and code, so a text with an even number of pieces has an
// unmatched backtick and is kept whole.
fn ticked(text: String) -> List(Element(message)) {
  let pieces = string.split(text, "`")
  case list.length(pieces) % 2 {
    0 -> [html.text(text)]
    _ ->
      list.index_map(pieces, fn(piece, index) {
        case index % 2 {
          0 -> html.text(piece)
          _ ->
            html.code([attribute.class("step-error-code")], [html.text(piece)])
        }
      })
  }
}

// A row's line, and its body behind one chevron when it has one. The element
// is drawn only when there is a body, so the chevron means more to read.
fn openable(
  attributes: List(attribute.Attribute(message)),
  head: List(Element(message)),
  body: List(Element(message)),
) -> Element(message) {
  let line = html.span([attribute.class("row-head")], head)
  case body {
    [] -> html.div([attribute.class("flat"), ..attributes], [line])
    [_, ..] ->
      element.element("loom-expand", [attribute.class("expand"), ..attributes], [
        html.span(
          [attribute.attribute("slot", "head"), attribute.class("row-head")],
          head,
        ),
        html.div(
          [attribute.attribute("slot", "body"), attribute.class("row-body")],
          body,
        ),
      ])
  }
}

// The line's words as spans: the verb, what it acted on in the face its kind
// calls for, and the lines an edit changed.
fn spoken(words: Words) -> List(Element(message)) {
  [
    [html.span([attribute.class("verb")], [html.text(words.verb)])],
    case words.subject {
      step_words.Mono(text:) -> [
        html.span([attribute.class("subject"), attribute.class("mono")], [
          html.text(text),
        ]),
      ]
      step_words.Prose(text:) -> [
        html.span([attribute.class("subject")], [html.text(text)]),
      ]
      step_words.Figure(text:) -> [
        html.span([attribute.class("figure")], [html.text("· " <> text)]),
      ]
      step_words.Unnamed -> []
    },
    case words.change {
      Some(step_words.Change(added:, removed:)) -> [
        html.span([attribute.class("change")], [
          html.span([attribute.class("added")], [
            html.text("+" <> int.to_string(added)),
          ]),
          html.span([attribute.class("removed")], [
            html.text("−" <> int.to_string(removed)),
          ]),
        ]),
      ]
      None -> []
    },
  ]
  |> list.flatten
}

fn standing_class(standing: turns.Standing) -> attribute.Attribute(message) {
  case standing {
    turns.Pending -> attribute.class("pending")
    turns.Done -> attribute.class("done")
    turns.Failed -> attribute.class("failed")
  }
}

fn glyph(standing: turns.Standing) -> String {
  case standing {
    turns.Pending -> "●"
    turns.Done -> "✓"
    turns.Failed -> "✕"
  }
}

// The word for how a call stands, kept in the row for assistive technology
// after the glyph that shows it.
fn state(standing: turns.Standing) -> String {
  case standing {
    turns.Pending -> " running"
    turns.Done -> " done"
    turns.Failed -> " failed"
  }
}

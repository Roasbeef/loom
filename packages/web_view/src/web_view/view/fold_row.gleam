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
import gleam/option.{None, Some}
import gleam/result
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

/// Whether a settled reasoning row may take the open state of a live row
/// that has just settled into it. The server marks the newest settled
/// reasoning row of the lane `Takes` and every other `Declines`.
pub type Handoff {
  /// The newest settled reasoning row of the lane.
  Takes

  /// Any other settled reasoning row.
  Declines
}

/// A reasoning block as a row: its words (`Reasoning · 162 lines · 4s`), then
/// a one-line preview of what the model wrote, with the whole reasoning behind
/// them. The preview is Markdown cut to one line (`markdown_view.line`), so a
/// glance says what the model was thinking, and it ends in an ellipsis when
/// it is cut. A block with nothing more than the preview to say passes no
/// body and is drawn as a line with no chevron.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.reasoning(words, [fold_row.preview_span([html.text("Check 7")])], [thought_rows], fold_row.Takes)
/// ```
pub fn reasoning(
  words: Words,
  preview: List(Element(message)),
  body: List(Element(message)),
  heir: Handoff,
) -> Element(message) {
  openable(
    [
      attribute.class("step"),
      attribute.class("thought"),
      attribute.attribute("kind", "settled"),
      attribute.attribute("handoff", case heir {
        Takes -> "yes"
        Declines -> "no"
      }),
    ],
    list.append(spoken(words), preview),
    body,
  )
}

/// A reasoning block still streaming as a row of the same shape: `head` is
/// the row's own words (the verb and a clock the browser counts), then the
/// one-line preview of the latest line, with the reasoning so far behind the
/// chevron. The row is marked `kind="live"`, so `<loom-expand>` keeps its
/// open state for the settled row that replaces it (`kind="settled"`).
///
/// ## Examples
///
/// ```gleam
/// // fold_row.live_reasoning([verb, clock], [html.text("Checking 7")], [so_far])
/// ```
pub fn live_reasoning(
  head: List(Element(message)),
  preview: List(Element(message)),
  body: List(Element(message)),
) -> Element(message) {
  openable(
    [
      attribute.class("step"),
      attribute.class("thought"),
      attribute.attribute("kind", "live"),
    ],
    list.append(head, previewed(preview)),
    body,
  )
}

// The one-line preview after a row's words, or nothing when there is none.
fn previewed(preview: List(Element(message))) -> List(Element(message)) {
  case preview {
    [] -> []
    [_, ..] -> [preview_span(preview)]
  }
}

/// The span a reasoning row's one-line preview is drawn in. `reasoning` takes
/// its preview already drawn, as a list holding this span or nothing, so the
/// caller can memoize it.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.preview_span([html.text("Check 7")])
/// ```
pub fn preview_span(children: List(Element(message))) -> Element(message) {
  html.span([attribute.class("subject"), attribute.class("preview")], children)
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

/// The rows a step opens to. A failed call that has the engine's refusal opens
/// on one plain sentence and the engine's text beneath it (`failure`), in place
/// of the call's summary, which the step's own line already says and which
/// names the tool the way the model spelled it. A failed step with no refusal,
/// such as a rejected program, whose rows carry their own title and reason,
/// keeps its rows as they are, and so does a step that is running or done.
///
/// ## Examples
///
/// ```gleam
/// // fold_row.step_body(turns.Failed, words, rows, draw)
/// ```
pub fn step_body(
  standing: turns.Standing,
  words: Words,
  rows: List(Line),
  draw: fn(Line) -> Element(message),
) -> List(Element(message)) {
  let #(refusal, rest) =
    list.partition(rows, fn(row) {
      row.speaker == transcript_line.ToolResult
      || row.speaker == transcript_line.ToolFailure
    })
  let engine =
    refusal
    |> list.map(refused_text)
    |> string.join("\n")
    |> string.trim
  case standing, engine {
    turns.Failed, "" | turns.Pending, _ | turns.Done, _ ->
      list.map(rows, line_row(_, draw))
    turns.Failed, _ -> [
      failure(step_words.failure_sentence(words, engine), engine),
      ..list.map(rest, line_row(_, draw))
    ]
  }
}

// What the engine said when it refused a call. A failed call's row opens with
// the call's own summary (`fs_edit`), which the step's line already says, and
// the refusal follows on the lines after it; a result row is the refusal
// whole.
fn refused_text(row: Line) -> String {
  case row.speaker == transcript_line.ToolFailure {
    False -> row.text
    True ->
      string.split_once(row.text, "\n")
      |> result.map(fn(parts) { parts.1 })
      |> result.unwrap("")
  }
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

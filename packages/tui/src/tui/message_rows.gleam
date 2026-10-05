//// The rows of a message one agent sent another.
////
//// Three kinds of agent traffic reach a transcript, and each has its own
//// mark so a reader can tell them apart at a glance: a message this strand
//// sent (`→ to sub:tests`), one a sibling strand sent (`← from sub:docs`),
//// and one another session's agent sent (`⇄ peer`). The kind is the line's
//// speaker, which `session_view/transcript_lines` chooses from the call or
//// from the stored origin and never from the text. A line's text is its
//// heading, a newline, and its body, and this module draws the heading as a
//// heading and the body as a body: a body that reads `⇄ peer ops-bot · ✓
//// origin` is drawn as body text under its sender's bar, because nothing
//// here builds a heading out of a body.
////
//// A sent or sibling message hangs from a bar in the margin column to the
//// left of the transcript, in the other strand's hue, so a run of traffic
//// with one strand reads as one thread. The bar is the row's first span and
//// `render` paints it one cell left of the row (`margin_bar`), which leaves
//// the row's own cells, and so its copy gutter, where every other row has
//// them. A peer message is a band across the pane instead, with the
//// daemon's check on its origin in the success colour, and its body behind
//// a bar of its own.

import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/string
import session_view/text_hygiene
import session_view/transcript_line.{
  type Speaker, Assistant, Failure, ImageRow, PeerMessage, ProgramFailure,
  ProgramRunning, ProgramSettled, Reasoning, ReasoningDigest, SentMessage,
  Spacer, StrandMessage, SummarizedAdvice, SummarizedReasoning, System, ToolCall,
  ToolDetail, ToolFailure, ToolGroup, ToolPatch, ToolResult, User,
}
import session_view/transcript_lines
import tui/markdown
import tui/theme

/// The glyph a margin bar is drawn with. A row whose first span is exactly
/// this glyph has it painted in the margin column, one cell left of the
/// row's own first cell.
pub const margin_bar = "▎"

/// The rows a message line draws in a pane `width` cells wide: a blank, the
/// heading and the body. The message closes bare, as a call does
/// (`transcript_lines.closes_bare`): the block after it brings the blank
/// above itself, so a run of messages is one blank row apart rather than
/// two. The heading is always one row, cut to
/// the pane, so a heading that gains words when a result arrives (`admitted
/// to its queue`) keeps the line's height.
///
/// ## Examples
///
/// ```gleam
/// let rows =
///   message_rows.rows(
///     transcript_line.SentMessage,
///     "→ to sub:tests · agent_send\nRun the tests.",
///     80,
///   )
/// ```
pub fn rows(speaker: Speaker, text: String, width: Int) -> List(span.Line) {
  let #(heading, body) = case string.split_once(text, "\n") {
    Ok(pair) -> pair
    Error(Nil) -> #(text, "")
  }
  let drawn = case speaker {
    PeerMessage -> peer_rows(heading, body, width)
    SentMessage -> thread_rows("→ to ", heading, body, width)
    StrandMessage -> thread_rows("← from ", heading, body, width)

    // Only the three message speakers reach this module; any other line
    // drawn here is its text as body rows, which is the safe reading.
    System
    | ToolGroup
    | User
    | Assistant
    | Reasoning
    | ReasoningDigest
    | SummarizedReasoning
    | SummarizedAdvice
    | ToolCall
    | ToolResult
    | ToolDetail
    | ToolPatch
    | ToolFailure
    | Failure
    | Spacer
    | ProgramRunning
    | ProgramFailure
    | ProgramSettled
    | ImageRow(..) -> body_rows(text, [], width)
  }
  list.append(drawn, [span.line_plain("")])
}

// A sent or sibling message: the heading behind one blank cell, the body
// behind three, and the other strand's bar in the margin beside both. The
// strand's name is what follows the heading's verb, up to its first
// separator, and it is drawn bold in that strand's hue.
fn thread_rows(
  verb: String,
  heading: String,
  body: String,
  width: Int,
) -> List(span.Line) {
  let after = string.drop_start(heading, string.length(verb))
  let #(name, rest) = case string.split_once(after, " · ") {
    Ok(#(name, rest)) -> #(name, " · " <> rest)
    Error(Nil) -> #(after, "")
  }
  let hue = strand_hue(name)
  let bar =
    span.span_styled(margin_bar, style.new(hue, style.Default, style.none()))
  let quiet = theme.quiet_text()
  let top =
    span.line_new([
      bar,
      span.span_plain(" "),
      ..clipped(
        [
          #(verb, quiet),
          #(name, style.new(hue, style.Default, style.bold())),
          #(rest, quiet),
        ],
        width - 1,
      )
    ])
  [top, ..body_rows(body, [bar, span.span_plain("   ")], width - 3)]
}

// A peer message: a band whose heading names the source session and strand
// in the advisor accent, with the daemon's check on the origin in the
// success colour, and the body behind a bar two cells in.
fn peer_rows(heading: String, body: String, width: Int) -> List(span.Line) {
  let band = fn(color, modifier) { style.new(color, theme.raised, modifier) }
  let #(name, rest) = case string.split_once(heading, " · ") {
    Ok(#(name, rest)) -> #(name, " · " <> rest)
    Error(Nil) -> #(heading, "")
  }

  // The check is the heading's last words but for the clock time, which
  // only a `PeerOrigin` puts there; it is split off by position, so a
  // session or strand that holds the same words cannot colour anything but
  // its own field.
  let #(rest, clock) = split_clock(rest)
  let #(middle, checked) = case
    string.ends_with(rest, transcript_lines.origin_checked)
  {
    True -> #(
      string.drop_end(rest, string.length(transcript_lines.origin_checked)),
      transcript_lines.origin_checked,
    )
    False -> #(rest, "")
  }
  let top =
    span.line_new(clipped(
      [
        #(name, band(theme.advisor, style.bold())),
        #(middle, band(theme.quiet, style.none())),
        #(checked, band(theme.added, style.bold())),
        #(clock, band(theme.quiet, style.none())),
      ],
      width,
    ))
  let bar =
    span.span_styled(
      "┃ ",
      style.new(theme.advisor, style.Default, style.none()),
    )
  [top, ..body_rows(body, [span.span_plain("  "), bar], width - 4)]
}

// A heading's trailing clock time, ` · 14:02`, split from the words before
// it, or nothing when the heading has none.
fn split_clock(heading: String) -> #(String, String) {
  let tail = string.slice(heading, string.length(heading) - 8, 8)
  case string.to_graphemes(tail) {
    [" ", "·", " ", h1, h2, ":", m1, m2] ->
      case int.parse(h1 <> h2), int.parse(m1 <> m2) {
        Ok(_), Ok(_) -> #(string.drop_end(heading, 8), tail)
        _, _ -> #(heading, "")
      }
    _ -> #(heading, "")
  }
}

// The body as plain text, each of its lines wrapped to `room` on its own
// and drawn behind `prefix`. An agent writes a message as lines, and
// Markdown would join two of them into one paragraph; kept as text, a
// message reads as it was sent. The body's own words never become a heading
// here: whatever they say, they are the rows under one. The message closes
// with a blank row of its own, so the body's last blanks are dropped rather
// than drawn as a bar with nothing beside it.
fn body_rows(
  body: String,
  prefix: List(span.Span),
  room: Int,
) -> List(span.Line) {
  let room = int.max(1, room)
  body
  |> text_hygiene.multiline
  |> string.split("\n")
  |> list.flat_map(fn(line) {
    case string.trim(line) {
      "" -> [span.line_plain("")]
      _ -> markdown.wrap_line(span.line_plain(line), room)
    }
  })
  |> list.reverse
  |> list.drop_while(fn(line) { span.line_width(line) == 0 })
  |> list.reverse
  |> list.map(fn(line) {
    span.Line(..line, spans: list.append(prefix, line.spans))
  })
}

// Styled pieces laid end to end and cut at `room` cells, the piece that
// crosses the edge ending in an ellipsis and the pieces after it dropped.
// Empty pieces draw nothing, so a heading without a check is not followed
// by an empty span.
fn clipped(pieces: List(#(String, style.Style)), room: Int) -> List(span.Span) {
  let #(spans, _) =
    list.fold(pieces, #([], int.max(0, room)), fn(acc, piece) {
      let #(spans, left) = acc
      let #(content, piece_style) = piece
      let cells = text.cell_width(content)
      case content, cells <= left {
        "", _ -> acc
        _, True -> #(
          [span.span_styled(content, piece_style), ..spans],
          left - cells,
        )
        _, False if left > 0 -> #(
          [
            span.span_styled(text.truncate(content, left, "…"), piece_style),
            ..spans
          ],
          0,
        )
        _, False -> acc
      }
    })
  list.reverse(spans)
}

/// The hue a strand's traffic is drawn in: one of three accents, chosen
/// from the strand's name so a strand keeps its hue across every message
/// and every frame. Body text's own colour is never one of them, so a bar
/// always reads as a strand's.
///
/// ## Examples
///
/// ```gleam
/// assert message_rows.strand_hue("sub:tests") == message_rows.strand_hue("sub:tests")
/// ```
pub fn strand_hue(name: String) -> style.Color {
  let sum =
    name
    |> string.to_utf_codepoints
    |> list.fold(0, fn(total, point) {
      total + string.utf_codepoint_to_int(point)
    })
  case sum % 3 {
    0 -> theme.added
    1 -> theme.current
    _ -> theme.advisor
  }
}

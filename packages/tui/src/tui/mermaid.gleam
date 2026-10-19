//// Mermaid diagrams as terminal text.
////
//// A model that explains a design will often write a diagram as a fenced
//// `mermaid` block. A terminal cannot run Mermaid's renderer, and sending
//// the diagram to a browser or an image would leave the transcript, so this
//// module draws the two diagram families a conversation actually uses,
//// flowcharts and sequence diagrams, as box-drawing characters. It is pure:
//// it reads a string and returns styled lines, with no process, no file and
//// no escape sequence, so it is safe to run on every streamed delta and its
//// output is as portable as any other transcript text.
////
//// The renderer draws a subset and refuses the rest. A diagram it cannot
//// draw faithfully is a typed `Refusal`, never a partial drawing, and the
//// caller shows the source instead with `reason` beside it. The drawing's
//// width is checked against the room the caller has: a flowchart that is too
//// wide in its declared direction is tried in the transposed one, and a
//// diagram that fits neither is refused as too wide. The limits are declared
//// in `tui/mermaid/model`.
////
//// ## Flow
////
//// `render` → `parse.parse` → `fit` → `draw.flowchart` or `sequence.draw` →
//// `lines`
////
//// 1. `render` parses the source into a `Diagram`.
//// 2. `fit` draws a flowchart in its declared direction and, when that is wider
////    than the room, in the transposed direction; a sequence diagram has one
////    layout and is drawn once.
//// 3. `lines` turns the canvas into styled lines, one span per run of cells
////    that share a role.

import etui/span
import etui/style
import gleam/int
import gleam/list
import gleam/result
import tui/mermaid/canvas.{type Canvas}
import tui/mermaid/draw
import tui/mermaid/model.{type Direction, type Flowchart, type Refusal}
import tui/mermaid/parse
import tui/mermaid/sequence
import tui/theme

/// Draws Mermaid source as styled terminal lines no wider than `width`.
///
/// On a refusal nothing is drawn and the caller keeps the source. Every
/// returned line is at most `width` cells wide.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(lines) = mermaid.render("graph TD\nA --> B", 80)
/// ```
pub fn render(source: String, width: Int) -> Result(List(span.Line), Refusal) {
  use diagram <- result.try(parse.parse(source))
  use drawn <- result.try(case diagram {
    model.Flow(chart) -> fit(chart, width)
    model.Sequenced(sequence) -> sequence.draw(sequence)
  })
  case canvas.drawn_width(drawn) <= width {
    True -> Ok(lines(drawn))
    False -> Error(model.TooWide)
  }
}

// The first direction that draws within the width, the declared one before the
// transposed one. If neither fits, the declared drawing is returned for the
// caller's width check to refuse, so a refusal always names the declared one.
fn fit(chart: Flowchart, width: Int) -> Result(Canvas, Refusal) {
  let declared = draw.flowchart(chart, chart.direction)
  case declared {
    Ok(drawn) ->
      case canvas.drawn_width(drawn) <= width {
        True -> Ok(drawn)
        False -> transposed_or(drawn, chart, width)
      }
    Error(refusal) ->
      case draw.flowchart(chart, transpose(chart.direction)) {
        Ok(drawn) -> Ok(drawn)
        Error(_) -> Error(refusal)
      }
  }
}

fn transposed_or(
  declared: Canvas,
  chart: Flowchart,
  width: Int,
) -> Result(Canvas, Refusal) {
  case draw.flowchart(chart, transpose(chart.direction)) {
    Ok(drawn) ->
      case canvas.drawn_width(drawn) <= width {
        True -> Ok(drawn)
        False -> Ok(declared)
      }
    Error(_) -> Ok(declared)
  }
}

fn transpose(direction: Direction) -> Direction {
  case direction {
    model.TopDown | model.BottomUp -> model.LeftRight
    model.LeftRight | model.RightLeft -> model.TopDown
  }
}

fn lines(drawn: Canvas) -> List(span.Line) {
  canvas.rows(drawn)
  |> list.map(fn(runs) {
    case runs {
      [] -> span.line_plain("")
      _ -> span.line_new(list.map(runs, run_span))
    }
  })
}

fn run_span(run: canvas.Run) -> span.Span {
  case run.role {
    canvas.Plain -> span.span_plain(run.text)
    canvas.Frame -> span.span_styled(run.text, theme.quiet_text())
    canvas.Wire -> span.span_styled(run.text, theme.quiet_text())
    canvas.Body -> span.span_styled(run.text, body_style())
    canvas.Label -> span.span_styled(run.text, theme.inline_code())
    canvas.Head -> span.span_styled(run.text, theme.current_bold())
  }
}

fn body_style() -> style.Style {
  style.new(theme.paper, style.Default, style.none())
}

/// A short phrase saying why a diagram was not drawn, for the line shown
/// under the source that replaces it.
///
/// ## Examples
///
/// ```gleam
/// mermaid.reason(model.TooWide)
/// // -> "too wide for this terminal"
/// ```
pub fn reason(refusal: Refusal) -> String {
  case refusal {
    model.Unsupported(what:) -> "not drawn: " <> what <> " are not supported"
    model.Malformed(line:, expected:) ->
      "not drawn: line " <> int.to_string(line) <> " expected " <> expected
    model.TooLarge(limit:) ->
      "not drawn: " <> limit_name(limit) <> " over limit"
    model.Unmeasurable(..) ->
      "not drawn: a label has characters with no fixed width"
    model.TooWide -> "not drawn: too wide for this terminal"
    model.Unroutable -> "not drawn: no clear path for every edge"
  }
}

fn limit_name(limit: model.Limit) -> String {
  case limit {
    model.SourceBytes -> "source size"
    model.Nodes -> "node count"
    model.Edges -> "edge count"
    model.LabelCells -> "label width"
    model.CanvasCells -> "diagram size"
  }
}

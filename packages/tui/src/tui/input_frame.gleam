//// The identity line above the transcript and the frame around the input.
////
//// The terminal used to spend a header row, up to three footer rows and a
//// status band on facts that sat apart from the prompt they describe. The
//// design splits them by how often they change. What does not change while
//// a turn runs (the workspace, the session, the strand being viewed, the
//// model) is one slim identity line on top, so a screenshot or a recording
//// always says which session it shows. Everything live sits in the rules of
//// the input's own frame, where the eye already is when typing:
////
//// ```text
//// ╭─ To main · Enter queues · Tab steers ───── ◐ code_mode · 12s · queue 1 · Esc interrupts ─╮
//// │ › ← sessions · ↓ agents · / commands                                                      │
//// ╰─ Kimi-K3 · low › ctx ~41% › est $1.86 ───────────────────────────────────── 1 needs you ─╯
//// ```
////
//// The top rule's left says where Enter sends and what it does, in keys
//// rather than sentences; its right says what the strand is doing, for how
//// long, how much is queued and how to stop it. The bottom rule's left is
//// the model, context and cost and nothing else; its right is how many
//// agents need the operator, drawn only while any do. A notice, and the
//// reason behind an unusual key, sit in the status band inside the frame
//// (`layout.composer_status_lines`), not on its rules. Every label is drawn from a
//// `Status` the caller builds from the model, so this module reads no model
//// and decides only geometry: what fits, and what gives way first when it
//// does not.

import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/text
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/text_hygiene
import tui/theme

/// What the identity line names.
@internal
pub type Identity {
  Identity(
    /// The workspace's last path segment, `pi-gui`.
    workspace: String,
    /// The session's display name.
    session: String,
    /// The strand the transcript and the composer are on.
    strand: String,
    /// The viewed sub-agent's task, when the strand is not `main`.
    task: Option(String),
    /// The strand's model, by its last path segment.
    model: String,
    /// The strand's reasoning effort, when the capture names one.
    effort: Option(String),
  )
}

/// What the strand is doing, for the top rule's right.
@internal
pub type Activity {
  /// Nothing is running on the strand.
  Resting

  /// The strand is working: the glyph's current frame, what it is doing and
  /// for how long, in the strip's spelled form.
  Busy(glyph: String, doing: String, elapsed: String)
}

/// Whether the input takes text, or is held while an approval is decided.
@internal
pub type Lock {
  /// Ordinary typing.
  Unlocked

  /// An approval is open; nothing typed here is sent until it is decided.
  Deciding
}

/// Every live fact the input frame draws.
@internal
pub type Status {
  Status(
    /// The recipient, already cut to keep its distinguishing suffix.
    target: String,
    /// What Enter, and Tab where it differs, do next.
    keys: String,
    /// What the strand is doing.
    activity: Activity,
    /// How many inputs wait in the strand's queue.
    queued: Int,
    /// The strand being viewed, named when it rests.
    strand: String,
    /// The model by its last path segment.
    model: String,
    /// The reasoning effort, when known.
    effort: Option(String),
    /// The context estimate, `ctx ~41%`.
    context: String,
    /// The session's estimated cost as a figure, `$1.86`, or `—` when none was
    /// priced (`transcript_lines.cost_figure`).
    cost: String,
    /// How many agents need the operator.
    needs: Int,
    /// Whether the input is held for an approval.
    lock: Lock,
  )
}

/// Paints the identity line on the raised background across its row.
///
/// The session and strand are the facts a reader needs, so they are fitted
/// first and the task gives way; the model keeps the right end.
///
/// ## Examples
///
/// ```gleam
/// // input_frame.render_identity(buf, header_area, identity)
/// ```
@internal
pub fn render_identity(
  buf: buffer.Buffer,
  area: Rect,
  identity: Identity,
) -> buffer.Buffer {
  let width = area.size.width
  let ground = theme.graphite
  let right =
    " "
    <> text_hygiene.single_line(identity.model)
    <> case identity.effort {
      Some(effort) -> " · " <> effort
      None -> ""
    }
    <> " "
  let right = text.truncate(right, int.max(0, width / 3), "…")
  let room = int.max(0, width - text.cell_width(right))
  let pieces = [
    #(" ◆ ", style.new(theme.signal, ground, style.bold())),
    #(
      text_hygiene.single_line(identity.workspace),
      style.new(theme.paper, ground, style.bold()),
    ),

    // A session named after its workspace, as a fresh one is, would say
    // the same word twice, so its name is left out.
    #(
      case identity.session == identity.workspace {
        True -> ""
        False -> " · " <> text_hygiene.single_line(identity.session)
      },
      style.new(theme.paper, ground, style.none()),
    ),
    #(" · strand ", style.new(theme.quiet, ground, style.none())),
    #(
      text_hygiene.single_line(identity.strand),
      style.new(theme.current, ground, style.bold()),
    ),
    ..case identity.task {
      Some(task) -> [
        #(
          " · " <> text_hygiene.single_line(task),
          style.new(theme.quiet, ground, style.none()),
        ),
      ]
      None -> []
    }
  ]
  let left = fit_spans(pieces, room)
  let used = spans_width(left)
  paragraph.render_styled(buf, area, [
    span.line_new(
      list.flatten([
        left,
        [
          span.span_styled(
            string.repeat(" ", int.max(0, room - used)),
            style.new(theme.quiet, ground, style.none()),
          ),
          span.span_styled(right, style.new(theme.quiet, ground, style.none())),
        ],
      ]),
    ),
  ])
}

// Spans in order until the room runs out; the span that crosses the edge is
// cut with an ellipsis and nothing after it is drawn.
fn fit_spans(
  pieces: List(#(String, style.Style)),
  room: Int,
) -> List(span.Span) {
  let #(spans, _) =
    list.fold(pieces, #([], room), fn(acc, piece) {
      let #(spans, left) = acc
      let width = text.cell_width(piece.0)
      case left, width <= left {
        0, _ -> acc
        _, True -> #(
          [span.span_styled(piece.0, piece.1), ..spans],
          left - width,
        )
        _, False -> #(
          [
            span.span_styled(text.truncate(piece.0, left, "…"), piece.1),
            ..spans
          ],
          0,
        )
      }
    })
  list.reverse(spans)
}

fn spans_width(spans: List(span.Span)) -> Int {
  list.fold(spans, 0, fn(total, piece) {
    total + text.cell_width(piece.content)
  })
}

/// The narrowest frame that keeps its full labels; below it the bottom rule
/// takes its compact form (no effort, no cost label) and the stop key is
/// spelled `Esc` alone.
const roomy = 100

/// The narrowest frame whose top rule carries what the strand is doing.
/// Below it the recipient and keys fill the rule, so the activity stays in
/// the status band above the editor (`layout.composer_status_lines`), where
/// it was before the frame carried it: a running turn must always say so.
@internal
pub const carries_activity = 72

/// Paints the input frame's rules and sides around `area`, leaving the
/// interior to the editor, the attachment chips and the status band.
///
/// ## Examples
///
/// ```gleam
/// // input_frame.render(buf, input_area, status)
/// ```
@internal
pub fn render(buf: buffer.Buffer, area: Rect, status: Status) -> buffer.Buffer {
  let width = area.size.width
  case width < 8 || area.size.height < 2 {
    True -> buf
    False -> {
      let x = area.position.x
      let top = area.position.y
      let bottom = geometry.bottom(area) - 1
      let rule = style.new(theme.signal, style.Default, style.none())

      // The rules carry their labels; the sides are plain, so the interior
      // keeps every cell the editor had before.
      let sides =
        list.repeat(Nil, int.max(0, area.size.height - 2))
        |> list.index_map(fn(_, row) { top + 1 + row })
      let painted =
        list.fold(sides, buf, fn(painted, y) {
          painted
          |> buffer.set_string(geometry.Position(x, y), "│", rule)
          |> buffer.set_string(geometry.Position(x + width - 1, y), "│", rule)
        })
      painted
      |> draw_rule(
        geometry.Position(x, top),
        width,
        #("╭", "╮"),
        top_left(status),
        top_right(status, width),
        KeepLeft,
      )
      |> draw_rule(
        geometry.Position(x, bottom),
        width,
        #("╰", "╯"),
        bottom_left(status, width),
        bottom_right(status),
        KeepRight,
      )
    }
  }
}

// Which label of a rule survives when the two do not both fit.
type Keep {
  // The left label is cut before the right gives way, as long as the right
  // keeps room beside a recipient: on the top rule, where the activity and
  // the key that interrupts it matter more than the end of the key hints.
  KeepLeft

  // The right label stays and the left is cut: on the bottom rule, where
  // the count of agents needing the operator outranks the cost.
  KeepRight
}

// One labelled rule: a corner, a dash, the left label, a run of dashes, the
// right label, a dash and the other corner.
fn draw_rule(
  buf: buffer.Buffer,
  at: geometry.Position,
  width: Int,
  corners: #(String, String),
  left: List(#(String, style.Style)),
  right: List(#(String, style.Style)),
  keep: Keep,
) -> buffer.Buffer {
  let rule = style.new(theme.signal, style.Default, style.none())
  let inner = width - 4
  let fits = labels_width(left) + labels_width(right) + 1 <= inner
  let #(left, right) = case fits, keep {
    True, _ -> #(left, right)
    False, KeepLeft -> #(left, case labels_width(right) + 12 <= inner {
      True -> right
      False -> []
    })
    False, KeepRight -> #(left, case labels_width(right) + 4 <= inner {
      True -> right
      False -> []
    })
  }
  let left = fit_spans(left, int.max(0, inner - labels_width(right) - 1))
  let used = spans_width(left) + labels_width(right)
  let line =
    span.line_new(
      list.flatten([
        [span.span_styled(corners.0 <> "─", rule)],
        left,
        [span.span_styled(string.repeat("─", int.max(0, inner - used)), rule)],
        list.map(right, fn(piece) { span.span_styled(piece.0, piece.1) }),
        [span.span_styled("─" <> corners.1, rule)],
      ]),
    )
  paragraph.render_styled(buf, geometry.rect_new(at.x, at.y, width, 1), [line])
}

fn labels_width(labels: List(#(String, style.Style))) -> Int {
  list.fold(labels, 0, fn(total, piece) { total + text.cell_width(piece.0) })
}

// Where Enter sends and what it does: the recipient in the signal colour,
// then the keys. A held input says why instead of naming keys it ignores.
fn top_left(status: Status) -> List(#(String, style.Style)) {
  let bold = style.new(theme.signal, style.Default, style.bold())
  let keys = case status.lock {
    Deciding -> "locked while deciding"
    Unlocked -> status.keys
  }
  let tail = case keys {
    "" -> ""
    _ -> " · " <> keys
  }
  [#(" To " <> status.target <> tail <> " ", bold)]
}

// What the strand is doing. The pieces give way from the end, so the glyph
// and the action stay longest; the stop key goes first, and on a narrow
// frame it is spelled `Esc` alone.
fn top_right(status: Status, width: Int) -> List(#(String, style.Style)) {
  let quiet = style.new(theme.quiet, style.Default, style.none())
  case status.activity, status.lock {
    _, Deciding -> []
    _, Unlocked if width < carries_activity -> []
    Resting, Unlocked -> [
      #(" ○ " <> text_hygiene.single_line(status.strand) <> " · idle ", quiet),
    ]
    Busy(glyph:, doing:, elapsed:), Unlocked -> {
      let queue = case status.queued {
        0 -> []
        count -> ["queue " <> int.to_string(count)]
      }
      let stop = case width < roomy {
        True -> "Esc"
        False -> "Esc interrupts"
      }
      let room = int.max(0, width / 2)
      let pieces =
        list.flatten([
          [text.truncate(text_hygiene.single_line(doing), room - 4, "…")],
          case elapsed {
            "" -> []
            elapsed -> [elapsed]
          },
          queue,
          [stop],
        ])
      [
        #(" ", quiet),
        #(glyph, style.new(theme.current, style.Default, style.bold())),
        #(" " <> joined(pieces, room - 3) <> " ", quiet),
      ]
    }
  }
}

// Joins pieces with ` · ` while they fit in `room`, dropping the rest.
fn joined(pieces: List(String), room: Int) -> String {
  list.fold(pieces, "", fn(drawn, piece) {
    let next = case drawn {
      "" -> piece
      _ -> drawn <> " · " <> piece
    }
    case text.cell_width(next) <= room {
      True -> next
      False -> drawn
    }
  })
}

// The model, context and cost, joined as omp joins them, with a notice in
// front while there is one. A narrow frame drops the effort and the word
// before the cost.
fn bottom_left(status: Status, width: Int) -> List(#(String, style.Style)) {
  let quiet = style.new(theme.quiet, style.Default, style.none())
  let model = case status.effort, width < roomy {
    Some(effort), False -> status.model <> " · " <> effort
    Some(_), True | None, _ -> status.model
  }
  let cost = case width < roomy {
    True -> status.cost
    False -> "est " <> status.cost
  }
  [
    #(
      " "
        <> text_hygiene.single_line(model)
        <> " › "
        <> status.context
        <> " › "
        <> cost
        <> " ",
      quiet,
    ),
  ]
}

// How many agents need the operator, in the danger colour, and nothing at
// all while none do.
fn bottom_right(status: Status) -> List(#(String, style.Style)) {
  case status.needs {
    0 -> []
    1 -> [
      #(" 1 needs you ", style.new(theme.danger, style.Default, style.bold())),
    ]
    count -> [
      #(
        " " <> int.to_string(count) <> " need you ",
        style.new(theme.danger, style.Default, style.bold()),
      ),
    ]
  }
}

/// The editor's rectangle inside the frame's interior: a blank cell, the
/// `›` prompt and a blank on the left, and one clear cell before the right
/// side, so typed text never touches the frame.
///
/// ## Examples
///
/// ```gleam
/// assert input_frame.prompt_area(geometry.rect_new(1, 5, 20, 1))
///   == geometry.rect_new(4, 5, 16, 1)
/// ```
@internal
pub fn prompt_area(interior: Rect) -> Rect {
  geometry.rect_new(
    interior.position.x + 3,
    interior.position.y,
    int.max(0, interior.size.width - 4),
    interior.size.height,
  )
}

/// The cells the frame's two sides and the prompt's margins take from a
/// row's width, so the editor wraps at the width it is drawn in.
@internal
pub const prompt_margin = 6

/// Paints the `›` prompt beside the editor's first row and, while the draft
/// is empty, the key hints as placeholder text after the cursor cell.
///
/// ## Examples
///
/// ```gleam
/// // input_frame.render_prompt(buf, editor_area, Some("← sessions · / commands"))
/// ```
@internal
pub fn render_prompt(
  buf: buffer.Buffer,
  editor: Rect,
  placeholder: Option(String),
) -> buffer.Buffer {
  let prompt =
    buffer.set_string(
      buf,
      geometry.Position(editor.position.x - 2, editor.position.y),
      "›",
      style.new(theme.signal, style.Default, style.bold()),
    )
  case placeholder {
    None -> prompt
    Some(hint) ->
      buffer.set_string(
        prompt,
        geometry.Position(editor.position.x + 1, editor.position.y),
        text.truncate(hint, int.max(0, editor.size.width - 1), "…"),
        style.new(theme.quiet, style.Default, style.none()),
      )
  }
}

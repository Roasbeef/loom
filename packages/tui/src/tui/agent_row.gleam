//// One agent drawn as one row, in the shape the agent strip and the agent
//// workspace's list share.
////
//// The strip under the input and the workspace list answer the same
//// question about the same strands, so a strand looks the same in both:
//// a status glyph, a name, what it is doing now, how long it has run and
//// how much context it holds, each in a column of its own. This module
//// owns that shape. The strip and the list differ only in how much room
//// they give the figures (`Shape`), and each host keeps its own cursor,
//// windowing and keys.
////
//// Every column has a fixed width for one list, so a reader can run an eye
//// down the glyphs, the names or the figures without reading across. What
//// does not fit is cut, and cut where it loses least: a name in the middle,
//// so the suffix that tells twins apart survives, and an action at a word.
//// The status glyph and the figures are never cut.

import etui/span
import etui/style
import etui/text
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/agent_roster
import session_view/agent_view
import session_view/text_hygiene
import tui/theme

/// The cells a table row's columns span: the mark, the glyph, a 24-cell
/// name, a 26-cell action and the two figure columns, with the gaps and the
/// margin between them.
@internal
pub const table_width = 69

/// Which list a row is drawn into, which decides how its figures read.
@internal
pub type Shape {
  /// The strip under the input: a wide name column and spelled figures,
  /// `4m 10s · 259k ctx`, right-aligned at the edge.
  StripRow

  /// The workspace list: narrower columns and compact figures, `4m10` and
  /// `259k`, in two right-aligned columns of their own.
  TableRow
}

/// What a row's leading mark says about it.
@internal
pub type Mark {
  /// The keyboard's cursor is on this row; it is drawn as the raised bar.
  Cursor

  /// The transcript and the composer are on this strand, but the cursor is
  /// not.
  Viewing

  /// Neither.
  Unmarked
}

/// Draws one list of agents, one row each, `width` cells wide, on
/// `ground`: the terminal's own background under the strip, the modal
/// background inside the workspace. The cursor's row is raised on either.
/// The cursor's mark is amber and bold; the viewed strand's is quiet, so one
/// column never shows two marks that both read as a selection.
///
/// The names are labelled together so a pair that share a slug both carry
/// their digest's head (`labels`), and the strip's figure columns are as
/// wide as the widest figure in the list, so the `·` between time and
/// context lines up down the strip.
///
/// ## Examples
///
/// ```gleam
/// // agent_row.rows(lines, agent_row.StripRow, 120, style.Default, fn(line) {
/// //   case line.id == cursor { True -> agent_row.Cursor False -> agent_row.Unmarked }
/// // })
/// ```
@internal
pub fn rows(
  lines: List(agent_roster.Line),
  shape: Shape,
  width: Int,
  ground: style.Color,
  mark: fn(agent_roster.Line) -> Mark,
) -> List(span.Line) {
  let names = labels(lines)
  let label = fn(line: agent_roster.Line) {
    case dict.get(names, line.id) {
      Ok(name) -> name
      Error(Nil) -> line.name
    }
  }
  let widths = widths(lines, label, shape, width)
  list.map(lines, fn(line) {
    row(line, label(line), mark(line), shape, width, ground, widths)
  })
}

/// The display name of each line, keyed by strand identity.
///
/// A sub-agent's name is its slug (`agent_roster.short_name`), which drops
/// the digest that makes it unique. Two reviewers spawned with one purpose
/// would then read the same, so a slug that two lines share gets the first
/// four characters of each one's digest back, and the middle cut keeps
/// them on screen.
///
/// ## Examples
///
/// ```gleam
/// // agent_row.labels(lines)
/// //   == dict.from_list([#("sub:main/review-48f3…", "review-48f3"), ...])
/// ```
@internal
pub fn labels(lines: List(agent_roster.Line)) -> Dict(String, String) {
  let counts =
    list.fold(lines, dict.new(), fn(counts, line) {
      dict.upsert(counts, line.name, fn(seen) {
        case seen {
          Some(count) -> count + 1
          None -> 1
        }
      })
    })
  list.fold(lines, dict.new(), fn(names, line) {
    let name = case dict.get(counts, line.name) {
      Ok(count) if count > 1 -> with_digest(line)
      Ok(_) | Error(Nil) -> line.name
    }
    dict.insert(names, line.id, text_hygiene.single_line(name))
  })
}

// The slug and the head of the digest, from the strand identity
// `sub:{parent}/{slug}-{digest}`. An identity not in that shape is shown
// whole, since it is already what tells the two apart.
fn with_digest(line: agent_roster.Line) -> String {
  let leaf =
    string.split(line.id, "/")
    |> list.last
    |> result_or(line.id)
  case string.split(leaf, "-") |> list.reverse {
    [digest, _, ..] -> line.name <> "-" <> string.slice(digest, 0, 4)
    [_] | [] -> leaf
  }
}

fn result_or(value: Result(String, Nil), fallback: String) -> String {
  case value {
    Ok(value) -> value
    Error(Nil) -> fallback
  }
}

// The widths of a list's name and figure columns. The strip sizes each to
// the widest it shows, so a short roster gives its actions the room a long
// name column would have taken, and caps the name at 36 cells (24 on a
// narrow screen, where the middle cut takes over). The table fixes all
// three, so its columns line up with its heading whatever the agents are.
type Widths {
  Widths(name: Int, elapsed: Int, context: Int)
}

fn widths(
  lines: List(agent_roster.Line),
  label: fn(agent_roster.Line) -> String,
  shape: Shape,
  width: Int,
) -> Widths {
  case shape {
    TableRow ->
      Widths(
        name: int.clamp(int.min(width, table_width) - 45, min: 8, max: 24),
        elapsed: 5,
        context: 6,
      )
    StripRow -> {
      let widest =
        list.fold(lines, Widths(0, 0, 0), fn(widest, line) {
          Widths(
            name: int.max(widest.name, text.cell_width(label(line))),
            elapsed: int.max(
              widest.elapsed,
              text.cell_width(spelled_time(line)),
            ),
            context: int.max(
              widest.context,
              text.cell_width(spelled_size(line)),
            ),
          )
        })
      let cap = case width >= 100 {
        True -> 36
        False -> int.clamp(width / 3, min: 8, max: 24)
      }
      Widths(..widest, name: int.clamp(widest.name, min: 8, max: cap))
    }
  }
}

fn spelled_time(line: agent_roster.Line) -> String {
  case line.elapsed_s {
    Some(seconds) -> agent_roster.duration(seconds)
    None -> ""
  }
}

fn spelled_size(line: agent_roster.Line) -> String {
  case line.tokens {
    Some(count) -> compact_count(count)
    None -> ""
  }
}

// One row. The lead is the mark and the glyph; then the name column; then
// the action, which takes whatever the fixed columns leave; then the
// figures, right-aligned. The cursor's row is painted raised across the
// full width so it reads as one bar.
fn row(
  line: agent_roster.Line,
  name: String,
  mark: Mark,
  shape: Shape,
  width: Int,
  ground: style.Color,
  widths: Widths,
) -> span.Line {
  let background = case mark {
    Cursor -> theme.raised
    Viewing | Unmarked -> ground
  }
  let weight = case mark {
    Cursor -> style.bold()
    Viewing | Unmarked -> style.none()
  }
  let lead = case shape, mark {
    StripRow, Cursor -> " ❯ "
    StripRow, Viewing | TableRow, Viewing -> " › "
    TableRow, Cursor -> " ▸ "
    StripRow, Unmarked | TableRow, Unmarked -> "   "
  }
  let #(glyph, tone) = glyph(line.id, line.status, background)
  let meter = meter(line, shape, widths)

  // The table's columns stop at the width its heading is drawn for, so a
  // wider list leaves the space after the figures rather than spreading the
  // columns apart; the raised bar still runs the full width.
  let columns = case shape {
    TableRow -> int.min(width, table_width)
    StripRow -> width
  }
  let name_width = widths.name

  // The action takes what the fixed columns leave, and is cut a cell short
  // of it so even a full action keeps two spaces before the figures.
  let room = columns - 3 - 2 - name_width - 1 - text.cell_width(meter) - 1
  let action_style = case agent_view.needs_attention(line.status), shape {
    True, _ -> style.new(theme.danger, background, style.none())
    False, StripRow -> style.new(theme.paper, background, style.none())
    False, TableRow -> style.new(theme.quiet, background, style.none())
  }
  let spans = [
    span.span_styled(lead, case mark {
      Cursor -> style.new(theme.signal, background, style.bold())
      Viewing | Unmarked -> style.new(theme.quiet, background, style.none())
    }),
    span.span_styled(glyph <> " ", tone),
    span.span_styled(
      text.pad_right(cut_middle(name, name_width), name_width) <> " ",
      style.new(theme.paper, background, weight),
    ),
    span.span_styled(
      text.pad_right(cut(line.text, int.max(0, room - 1)), int.max(0, room))
        <> " ",
      action_style,
    ),
    span.span_styled(meter, style.new(theme.quiet, background, style.none())),
  ]
  pad(span.line_new(spans), width, background)
}

// The figures at the end of a row, with the margin cell after them.
fn meter(line: agent_roster.Line, shape: Shape, figures: Widths) -> String {
  case shape {
    StripRow -> {
      let time = spelled_time(line)
      let size = spelled_size(line)
      case figures.elapsed, figures.context {
        0, 0 -> ""
        0, context -> text.pad_left(size, context) <> " ctx "
        elapsed, 0 -> text.pad_left(time, elapsed) <> " "
        elapsed, context -> {
          let joint = case time, size {
            "", _ | _, "" -> "   "
            _, _ -> " · "
          }
          let size = case size {
            "" -> string.repeat(" ", context + 4)
            size -> text.pad_left(size, context) <> " ctx"
          }
          text.pad_left(time, elapsed) <> joint <> size <> " "
        }
      }
    }
    TableRow ->
      text.pad_left(compact_time(line), figures.elapsed)
      <> text.pad_left(compact_size(line), figures.context)
      <> " "
  }
}

/// A compact elapsed time for a table column: `0m51`, `2m38`, `1h02`.
///
/// ## Examples
///
/// ```gleam
/// assert agent_row.compact_duration(158) == "2m38"
/// assert agent_row.compact_duration(3720) == "1h02"
/// ```
@internal
pub fn compact_duration(seconds: Int) -> String {
  let seconds = int.max(0, seconds)
  case seconds >= 3600 {
    True ->
      int.to_string(seconds / 3600) <> "h" <> pad2({ seconds % 3600 } / 60)
    False -> int.to_string(seconds / 60) <> "m" <> pad2(seconds % 60)
  }
}

/// A compact token count for a table column: `950`, `74k`, `1.2m`.
///
/// Every agent surface writes a context size this one way, so the strip,
/// the table and the detail read the same figure the same way: whole
/// thousands below a million, tenths of a million above it.
///
/// ## Examples
///
/// ```gleam
/// assert agent_row.compact_count(74_400) == "74k"
/// assert agent_row.compact_count(2_300_000) == "2.3m"
/// ```
@internal
pub fn compact_count(value: Int) -> String {
  case value >= 1_000_000, value >= 1000 {
    True, _ -> agent_roster.count_label(value)
    False, True -> int.to_string(value / 1000) <> "k"
    False, False -> int.to_string(int.max(0, value))
  }
}

fn compact_time(line: agent_roster.Line) -> String {
  case line.elapsed_s {
    Some(seconds) -> compact_duration(seconds)
    None -> ""
  }
}

fn compact_size(line: agent_roster.Line) -> String {
  case line.tokens {
    Some(count) -> compact_count(count)
    None -> ""
  }
}

fn pad2(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}

/// The glyph a strand's status is drawn with, and its colour. The advisor
/// has a mark of its own, since it reviews rather than works.
///
/// ## Examples
///
/// ```gleam
/// let #(glyph, _) = agent_row.glyph("main", agent_view.Failed, style.Default)
/// assert glyph == "×"
/// ```
@internal
pub fn glyph(
  id: String,
  status: agent_view.Status,
  background: style.Color,
) -> #(String, style.Style) {
  case id == agent_roster.advisor {
    True -> #("◆", style.new(theme.advisor, background, style.none()))
    False -> #(status_mark(status), status_style(status, background))
  }
}

/// The glyph that carries a status without colour.
///
/// ## Examples
///
/// ```gleam
/// assert agent_row.status_mark(agent_view.NeedsInput) == "?"
/// ```
@internal
pub fn status_mark(status: agent_view.Status) -> String {
  case status {
    agent_view.Working -> "●"
    agent_view.Waiting -> "◷"
    agent_view.NeedsInput -> "?"
    agent_view.Finished -> "✓"
    agent_view.Failed -> "×"
    agent_view.Halted -> "!"
    agent_view.Idle -> "○"
    agent_view.Unavailable -> "-"
  }
}

/// The colour a status is drawn in, on a given background. A strand that
/// needs the operator is drawn in the danger colour, the one hue reserved
/// for what asks for action.
///
/// ## Examples
///
/// ```gleam
/// // agent_row.status_style(agent_view.Working, theme.raised)
/// ```
@internal
pub fn status_style(
  status: agent_view.Status,
  background: style.Color,
) -> style.Style {
  case status {
    agent_view.Working -> style.new(theme.current, background, style.none())
    agent_view.Waiting | agent_view.Halted ->
      style.new(theme.signal, background, style.none())
    agent_view.NeedsInput -> style.new(theme.danger, background, style.bold())
    agent_view.Failed -> style.new(theme.danger, background, style.none())
    agent_view.Finished -> style.new(theme.added, background, style.none())
    agent_view.Idle | agent_view.Unavailable ->
      style.new(theme.quiet, background, style.none())
  }
}

/// Cuts a name to `width` cells in the middle, keeping its last five, so
/// `adversarial-code-review-48f3` and `adversarial-code-review-ec14` stay
/// distinct as `adversarial…-48f3` and `adversarial…-ec14`.
///
/// ## Examples
///
/// ```gleam
/// assert agent_row.cut_middle("adversarial-code-review-48f3", 16)
///   == "adversaria…-48f3"
/// ```
@internal
pub fn cut_middle(value: String, width: Int) -> String {
  let value = text_hygiene.single_line(value)
  case text.cell_width(value) <= width, width > 8 {
    True, _ -> value
    False, False -> text.truncate(value, width, "…")
    False, True -> {
      let tail = string.slice(value, string.length(value) - 5, 5)
      text.truncate(value, width - 6, "") <> "…" <> tail
    }
  }
}

/// Cuts text to `width` cells at a word boundary with an ellipsis, so a cut
/// never ends in half a word; a single word wider than the room is cut
/// where it must be.
///
/// ## Examples
///
/// ```gleam
/// assert agent_row.cut("Tracing publish_herdr reachability", 20)
///   == "Tracing…"
/// ```
@internal
pub fn cut(value: String, width: Int) -> String {
  let value = text_hygiene.single_line(value)
  case text.cell_width(value) <= width {
    True -> value
    False -> {
      let head = text.truncate(value, int.max(0, width - 1), "")
      let words = string.split(head, " ")
      let whole = case string.ends_with(head, " "), words {
        True, _ | False, [_] | False, [] -> head
        False, [_, _, ..] ->
          list.take(words, list.length(words) - 1) |> string.join(" ")
      }
      case width {
        0 -> ""
        _ -> trim_joint(whole) <> "…"
      }
    }
  }
}

// Drops the spaces and separators a cut leaves at its end, so the ellipsis
// follows a word rather than a dangling ` ·`.
fn trim_joint(value: String) -> String {
  case
    string.ends_with(value, " ")
    || string.ends_with(value, "·")
    || string.ends_with(value, ",")
  {
    True -> trim_joint(string.drop_end(value, 1))
    False -> value
  }
}

// Extends a line to `width` cells on `background`, so a raised bar has no
// ragged right edge.
fn pad(line: span.Line, width: Int, background: style.Color) -> span.Line {
  let used =
    list.fold(line.spans, 0, fn(total, piece) {
      total + text.cell_width(piece.content)
    })
  case used < width {
    True ->
      span.line_new(
        list.append(line.spans, [
          span.span_styled(
            string.repeat(" ", width - used),
            style.new(theme.quiet, background, style.none()),
          ),
        ]),
      )
    False -> line
  }
}

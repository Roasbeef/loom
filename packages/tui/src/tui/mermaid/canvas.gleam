//// A sparse character grid that diagrams are painted on.
////
//// Both diagram families draw the same way: place boxes and text, then run
//// lines between them. The canvas is the one place that knows what a cell
//// holds, so the router can ask whether a cell is free or already carries a
//// straight line it may cross, and so a crossing is a property of the data
//// rather than something each drawing routine has to remember.
////
//// A line cell stores which of its four sides are joined, as a bit mask,
//// not a glyph. The glyph is derived when the canvas is read out, which is
//// what makes a crossing automatic: two lines through one cell union their
//// masks into all four sides, and all four sides is `┼`. Two routes can
//// never merge into a corner or a tee, because the router only crosses a
//// line perpendicular to it and never runs along one.
////
//// Every cell is one terminal cell. A wide grapheme occupies its own cell
//// and a `Cont` placeholder after it, so a row's width is the number of
//// cells and never depends on how many characters the row holds. Writes
//// outside the canvas are dropped, which keeps a label that would run off
//// the edge from corrupting anything, and the callers check room first.

import etui/text
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui/mermaid/model.{type Box, type Shape, type Stroke}

/// What a run of text is, so the caller can colour it. The canvas itself
/// never emits styles.
pub type Role {
  /// Blank space.
  Plain

  /// A node's outline, a participant's box, or a note's box.
  Frame

  /// Node and participant text.
  Body

  /// An edge or a lifeline.
  Wire

  /// An edge label or a message label.
  Label

  /// An arrowhead or a cross.
  Head
}

/// One cell of the grid.
pub type Cell {
  /// A fixed glyph that no line may cross: outlines, text, arrowheads.
  Ink(glyph: String, role: Role)

  /// Part of a routed line, as the sides it joins.
  Line(mask: Int, stroke: Stroke)

  /// The second cell of a double-width glyph, drawn as nothing.
  Cont
}

/// The grid. Cells are absent until written, so an empty canvas costs
/// nothing however large its bounds.
pub opaque type Canvas {
  Canvas(cells: Dict(#(Int, Int), Cell), width: Int, height: Int)
}

/// A maximal run of cells that share a role, as text.
pub type Run {
  Run(text: String, role: Role)
}

/// The side bit for a line joined above its cell.
pub const up = 1

/// The side bit for a line joined below its cell.
pub const down = 2

/// The side bit for a line joined left of its cell.
pub const left = 4

/// The side bit for a line joined right of its cell.
pub const right = 8

/// An empty canvas of the given size in cells.
///
/// ## Examples
///
/// ```gleam
/// let canvas = canvas.new(10, 4)
/// ```
pub fn new(width: Int, height: Int) -> Canvas {
  Canvas(cells: dict.new(), width:, height:)
}

/// The canvas width in cells.
pub fn width(canvas: Canvas) -> Int {
  canvas.width
}

/// The canvas height in cells.
pub fn height(canvas: Canvas) -> Int {
  canvas.height
}

/// Whether a position lies inside the canvas.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(2, 2) |> canvas.contains(1, 1)
/// // -> True
/// ```
pub fn contains(canvas: Canvas, x: Int, y: Int) -> Bool {
  x >= 0 && y >= 0 && x < canvas.width && y < canvas.height
}

/// The cell at a position, if anything was written there.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(2, 2) |> canvas.cell(0, 0)
/// // -> None
/// ```
pub fn cell(canvas: Canvas, x: Int, y: Int) -> Option(Cell) {
  case dict.get(canvas.cells, #(x, y)) {
    Ok(found) -> Some(found)
    Error(_) -> None
  }
}

/// Whether a position is inside the canvas and still empty.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(2, 2) |> canvas.is_blank(0, 0)
/// // -> True
/// ```
pub fn is_blank(canvas: Canvas, x: Int, y: Int) -> Bool {
  contains(canvas, x, y) && !dict.has_key(canvas.cells, #(x, y))
}

/// Whether every cell of a rectangle, corners inclusive, is blank.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(5, 5) |> canvas.region_blank(0, 0, 4, 0)
/// // -> True
/// ```
pub fn region_blank(
  canvas: Canvas,
  from_x: Int,
  from_y: Int,
  to_x: Int,
  to_y: Int,
) -> Bool {
  list.all(between(from_y, to_y), fn(y) {
    list.all(between(from_x, to_x), fn(x) { is_blank(canvas, x, y) })
  })
}

/// The integers from `low` to `high` inclusive, empty when `high < low`.
///
/// ## Examples
///
/// ```gleam
/// canvas.between(2, 4)
/// // -> [2, 3, 4]
/// ```
pub fn between(low: Int, high: Int) -> List(Int) {
  case high < low {
    True -> []
    False ->
      list.map(model.indices(high - low + 1), fn(offset) { low + offset })
  }
}

/// Writes one glyph. A glyph two cells wide also claims the cell after it.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(3, 1) |> canvas.put_ink(0, 0, "x", canvas.Body)
/// ```
pub fn put_ink(
  canvas: Canvas,
  x: Int,
  y: Int,
  glyph: String,
  role: Role,
) -> Canvas {
  case contains(canvas, x, y) {
    False -> canvas
    True -> {
      let cells = dict.insert(canvas.cells, #(x, y), Ink(glyph:, role:))
      case text.cell_width(glyph) {
        2 -> Canvas(..canvas, cells: dict.insert(cells, #(x + 1, y), Cont))
        _ -> Canvas(..canvas, cells: cells)
      }
    }
  }
}

/// Writes a string left to right from a position, each grapheme in as many
/// cells as it is wide.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(5, 1) |> canvas.put_text(0, 0, "ab", canvas.Label)
/// ```
pub fn put_text(
  canvas: Canvas,
  x: Int,
  y: Int,
  content: String,
  role: Role,
) -> Canvas {
  let #(done, _) =
    list.fold(string.to_graphemes(content), #(canvas, x), fn(state, grapheme) {
      let #(current, at) = state
      #(put_ink(current, at, y, grapheme, role), at + text.cell_width(grapheme))
    })
  done
}

/// Joins sides onto a cell's line, creating the line if the cell is blank.
/// Two strokes meeting at one cell draw as the heavier one.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(3, 3)
/// |> canvas.add_line(1, 1, canvas.up + canvas.down, model.Solid)
/// ```
pub fn add_line(
  canvas: Canvas,
  x: Int,
  y: Int,
  mask: Int,
  stroke: Stroke,
) -> Canvas {
  case contains(canvas, x, y) {
    False -> canvas
    True -> {
      let merged = case dict.get(canvas.cells, #(x, y)) {
        Ok(Line(mask: existing, stroke: earlier)) ->
          Line(
            mask: int.bitwise_or(existing, mask),
            stroke: heavier(earlier, stroke),
          )
        _ -> Line(mask:, stroke:)
      }
      Canvas(..canvas, cells: dict.insert(canvas.cells, #(x, y), merged))
    }
  }
}

fn heavier(first: Stroke, second: Stroke) -> Stroke {
  case first, second {
    model.Thick, _ | _, model.Thick -> model.Thick
    model.Dotted, _ -> model.Dotted
    _, _ -> second
  }
}

/// The glyph for a line cell. A mask with one side, which routing never
/// produces, is drawn as the straight line it would extend.
///
/// ## Examples
///
/// ```gleam
/// canvas.line_glyph(canvas.up + canvas.down, model.Solid)
/// // -> "│"
/// ```
pub fn line_glyph(mask: Int, stroke: Stroke) -> String {
  case mask {
    m if m == up + down || m == up || m == down ->
      by_stroke(stroke, "│", "┆", "┃")
    m if m == left + right || m == left || m == right ->
      by_stroke(stroke, "─", "┄", "━")
    m if m == down + right -> by_stroke(stroke, "┌", "┌", "┏")
    m if m == down + left -> by_stroke(stroke, "┐", "┐", "┓")
    m if m == up + right -> by_stroke(stroke, "└", "└", "┗")
    m if m == up + left -> by_stroke(stroke, "┘", "┘", "┛")
    _ -> by_stroke(stroke, "┼", "┼", "╋")
  }
}

fn by_stroke(stroke: Stroke, solid: String, dotted: String, thick: String) {
  case stroke {
    model.Solid -> solid
    model.Dotted -> dotted
    model.Thick -> thick
  }
}

/// Paints a node's outline and its centred label lines into a box.
///
/// The label is written inside the outline, one row per line, centred in the
/// inner width. The box must be at least as wide as its widest line plus
/// four and as tall as its line count plus two; `layout` sizes it that way.
///
/// ## Examples
///
/// ```gleam
/// canvas.draw_box(canvas, model.Box(0, 0, 7, 3), model.Rectangle, ["Hi"])
/// ```
pub fn draw_box(
  canvas: Canvas,
  box: Box,
  shape: Shape,
  lines: List(String),
) -> Canvas {
  let #(top_left, top_right, bottom_left, bottom_right, across, upright) =
    outline(shape)
  let inner = box.width - 2
  let right_x = box.x + box.width - 1
  let bottom_y = box.y + box.height - 1
  let top = top_left <> string.repeat(across, inner) <> top_right
  let bottom = bottom_left <> string.repeat(across, inner) <> bottom_right

  let framed =
    canvas
    |> put_text(box.x, box.y, top, Frame)
    |> put_text(box.x, bottom_y, bottom, Frame)
  let sides =
    list.fold(between(box.y + 1, bottom_y - 1), framed, fn(current, y) {
      current
      |> put_ink(box.x, y, upright, Frame)
      |> put_ink(right_x, y, upright, Frame)
    })

  // A box taller than its label, made so for the edges that attach to it,
  // centres the label vertically as well.
  let above = { box.height - 2 - list.length(lines) } / 2
  list.index_fold(lines, sides, fn(current, line, row) {
    let pad = { inner - text.cell_width(line) } / 2
    put_text(current, box.x + 1 + pad, box.y + 1 + above + row, line, Body)
  })
}

// The six glyphs of a shape's outline: four corners, the horizontal bar and
// the vertical bar.
fn outline(shape: Shape) -> #(String, String, String, String, String, String) {
  case shape {
    model.Rectangle -> #("┌", "┐", "└", "┘", "─", "│")
    model.Rounded -> #("╭", "╮", "╰", "╯", "─", "│")
    model.Decision -> #("╔", "╗", "╚", "╝", "═", "║")
  }
}

/// Reads the canvas out as rows of runs, cropped to what was drawn.
///
/// The crop removes every blank column left of the leftmost cell and every
/// blank row above and below the drawing, then trims each row's trailing
/// blanks, so the margins the router reserved never reach the screen.
///
/// ## Examples
///
/// ```gleam
/// canvas.new(4, 1)
/// |> canvas.put_text(1, 0, "ab", canvas.Body)
/// |> canvas.rows
/// // -> [[canvas.Run("ab", canvas.Body)]]
/// ```
pub fn rows(canvas: Canvas) -> List(List(Run)) {
  case dict.keys(canvas.cells) {
    [] -> []
    [#(first_x, first_y), ..rest] as positions -> {
      let #(min_x, min_y, max_y) =
        list.fold(rest, #(first_x, first_y, first_y), fn(bounds, at) {
          #(
            int.min(bounds.0, at.0),
            int.min(bounds.1, at.1),
            int.max(bounds.2, at.1),
          )
        })
      let max_x =
        list.fold(positions, min_x, fn(top, at) { int.max(top, at.0) })
      between(min_y, max_y)
      |> list.map(fn(y) { row_runs(canvas, y, min_x, max_x) })
    }
  }
}

// One row as runs, with trailing blanks dropped.
fn row_runs(canvas: Canvas, y: Int, from_x: Int, to_x: Int) -> List(Run) {
  between(from_x, to_x)
  |> list.filter_map(fn(x) {
    case dict.get(canvas.cells, #(x, y)) {
      Ok(Ink(glyph:, role:)) -> Ok(Run(glyph, role))
      Ok(Line(mask:, stroke:)) -> Ok(Run(line_glyph(mask, stroke), Wire))
      Ok(Cont) -> Error(Nil)
      Error(_) -> Ok(Run(" ", Plain))
    }
  })
  |> merge_runs([])
  |> drop_trailing_blank
}

fn merge_runs(pieces: List(Run), done: List(Run)) -> List(Run) {
  case pieces, done {
    [], _ -> list.reverse(done)
    [piece, ..rest], [last, ..earlier] if piece.role == last.role ->
      merge_runs(rest, [Run(last.text <> piece.text, last.role), ..earlier])
    [piece, ..rest], _ -> merge_runs(rest, [piece, ..done])
  }
}

fn drop_trailing_blank(runs: List(Run)) -> List(Run) {
  case list.reverse(runs) {
    [Run(role: Plain, ..), ..rest] -> list.reverse(rest)
    _ -> runs
  }
}

/// The width in cells of the widest of some rows already read out. A caller
/// that needs both the rows and their width reads the canvas once and measures
/// the rows, rather than reading it twice.
///
/// ## Examples
///
/// ```gleam
/// canvas.rows_width([[canvas.Run("ab", canvas.Body)]])
/// // -> 2
/// ```
pub fn rows_width(read: List(List(Run))) -> Int {
  list.fold(read, 0, fn(widest, row) {
    int.max(
      widest,
      list.fold(row, 0, fn(total, run) { total + text.cell_width(run.text) }),
    )
  })
}

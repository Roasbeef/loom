//// The Mermaid reader: source text in, a `Diagram` or a `Refusal` out.
////
//// This is a reader for a subset, not for Mermaid. A model writes Mermaid
//// for a renderer that accepts almost anything, and this renderer draws
//// characters on a grid, so the subset is what a grid can draw honestly:
//// flowcharts with rectangular, rounded and decision nodes and three edge
//// strokes, and sequence diagrams with messages and notes. Anything else is a
//// typed refusal rather than a guess, because a half-drawn diagram misleads
//// where a source block does not. The caller keeps the source and shows it on
//// every refusal.
////
//// All limits are checked here, before layout, so the later stages can rely on
//// them: input size, node and edge counts, and label width in terminal cells.
//// Label width is measured with the same function the rest of the terminal
//// uses, and a label with a zero-width character is refused outright, since
//// the grid cannot place a box around text whose width it cannot trust.
////
//// ## Flow
////
//// `parse` → `parse_flowchart` or `parse_sequence`
////
//// 1. `parse` bounds the source, drops blank lines and `%%` comments, and
////    dispatches on the header word.
//// 2. `parse_flowchart` reads each statement with `parse_group`, `parse_node`
////    and `parse_edge`, chaining `A --> B --> C` and `A & B --> C` through
////    `parse_chain` and `add_edges`.
//// 3. `parse_sequence` reads one line at a time with `sequence_line`, which
////    sends a line to `parse_participant`, `parse_note` or `parse_message`.

import etui/text
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/mermaid/model.{
  type Diagram, type Direction, type Edge, type Event, type Flowchart,
  type MessageEnd, type Node, type NotePlace, type Participant, type Refusal,
  type Sequence, type Shape, type Stroke, type Tip,
}

// A source line with its one-based position, kept so a refusal can say where.
type Numbered =
  #(Int, String)

// The flowchart under construction. Nodes are kept in a dictionary keyed by
// their order of first appearance, so a later declaration can replace a label
// without disturbing the index every edge already holds.
type FlowBuilder {
  FlowBuilder(
    nodes: Dict(Int, Node),
    index: Dict(String, Int),
    count: Int,
    edges: List(Edge),
    edge_count: Int,
  )
}

// The sequence diagram under construction.
type SeqBuilder {
  SeqBuilder(
    people: Dict(Int, Participant),
    index: Dict(String, Int),
    count: Int,
    events: List(Event),
    event_count: Int,
  )
}

// Whether the statement splitter is inside a double-quoted label.
type Quoting {
  Quoted
  Unquoted
}

// The characters an identifier may hold. Mermaid allows more, but the rest
// collides with edge syntax, and a refusal is better than a wrong split.
const id_alphabet =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

// A flowchart line that opens with one of these words is a construct the
// grid cannot draw.
const flow_keywords = [
  "subgraph", "end", "classDef", "class", "style", "linkStyle", "click",
  "direction", "accTitle", "accDescr", "callback", "href",
]

// A sequence line that opens with one of these words is a construct this
// renderer leaves out.
const sequence_keywords = [
  "autonumber", "activate", "deactivate", "loop", "alt", "else", "opt", "par",
  "and", "critical", "option", "break", "rect", "end", "box", "title", "create",
  "destroy", "link", "links", "properties", "details", "accTitle", "accDescr",
]

/// Reads Mermaid source into a diagram, or says why it cannot.
///
/// The source is bounded first, so nothing downstream sees more than
/// `model.max_source_bytes`. Blank lines and `%%` comments are skipped; a
/// `%%{` directive and a front-matter block are refused because they change
/// how Mermaid itself renders and this renderer would silently ignore them.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(model.Flow(chart)) = parse.parse("graph TD\nA --> B")
/// ```
pub fn parse(source: String) -> Result(Diagram, Refusal) {
  use _ <- result.try(check_size(source))
  use lines <- result.try(significant_lines(source))

  // Dispatch diagram parsing based on header line.
  case lines {
    [] -> Error(model.Malformed(1, "a diagram header"))
    [#(number, header), ..rest] -> dispatch(number, header, rest)
  }
}

// The source size is measured in bytes because that is what bounds the work.
fn check_size(source: String) -> Result(Nil, Refusal) {
  case bit_array.byte_size(<<source:utf8>>) > model.max_source_bytes {
    True -> Error(model.TooLarge(model.SourceBytes))
    False -> Ok(Nil)
  }
}

/// Blank lines and comments carry no diagram. Directives and front matter are
/// refused here, before the header is read, because either could appear first.
fn significant_lines(source: String) -> Result(List(Numbered), Refusal) {
  source
  |> string.replace("\r\n", "\n")
  |> string.split("\n")
  |> list.index_map(fn(line, position) { #(position + 1, string.trim(line)) })
  |> list.try_fold([], fn(kept, entry) {
    case entry.1 {
      "" -> Ok(kept)
      "%%{" <> _ -> Error(model.Unsupported("%%{ directive"))
      "%%" <> _ -> Ok(kept)
      "---" <> _ if kept == [] -> Error(model.Unsupported("front matter"))
      _ -> Ok([entry, ..kept])
    }
  })
  |> result.map(list.reverse)
}

/// Dispatches diagram source lines based on the leading keyword in the header.
fn dispatch(
  number: Int,
  header: String,
  rest: List(Numbered),
) -> Result(Diagram, Refusal) {
  case words(header) {
    ["sequenceDiagram", ..] ->
      parse_sequence(rest) |> result.map(model.Sequenced)
    [keyword, ..] if keyword == "flowchart" || keyword == "graph" ->
      parse_flowchart(number, header, rest) |> result.map(model.Flow)
    [other, ..] -> Error(model.Unsupported("diagram type `" <> other <> "`"))
    [] -> Error(model.Malformed(number, "a diagram header"))
  }
}

fn words(text: String) -> List(String) {
  text
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
}

// ---------------------------------------------------------------------------
// Flowcharts
// ---------------------------------------------------------------------------

/// Parses flowchart statements and builds a Flowchart model.
fn parse_flowchart(
  number: Int,
  header: String,
  rest: List(Numbered),
) -> Result(Flowchart, Refusal) {
  // Separate flowchart direction keyword from any statements on the header line.
  let #(head, trailing) = case split_statements(header) {
    [first, ..more] -> #(first, more)
    [] -> #(header, [])
  }

  use direction <- result.try(parse_direction(number, head))

  // Statements that share the header's line are read before the later lines,
  // in source order, so a node's first appearance is its position in the text.
  let statements =
    list.append(
      list.map(trailing, fn(text) { #(number, text) }),
      list.flat_map(rest, fn(entry) {
        split_statements(entry.1)
        |> list.map(fn(text) { #(entry.0, text) })
      }),
    )
  let start =
    FlowBuilder(
      nodes: dict.new(),
      index: dict.new(),
      count: 0,
      edges: [],
      edge_count: 0,
    )
  use built <- result.try(
    list.try_fold(statements, start, fn(builder, statement) {
      parse_statement(builder, statement.1, statement.0)
    }),
  )

  // Require at least one node declared in flowchart.
  case built.count {
    0 -> Error(model.Malformed(number, "at least one node"))
    _ ->
      Ok(model.Flowchart(
        direction:,
        nodes: node_list(built),
        edges: list.reverse(built.edges),
      ))
  }
}

fn node_list(builder: FlowBuilder) -> List(Node) {
  model.indices(builder.count)
  |> list.filter_map(fn(position) { dict.get(builder.nodes, position) })
}

/// Parses flowchart layout direction from header tokens.
fn parse_direction(number: Int, header: String) -> Result(Direction, Refusal) {
  case words(header) {
    [_] | [_, "TD"] | [_, "TB"] -> Ok(model.TopDown)
    [_, "BT"] -> Ok(model.BottomUp)
    [_, "LR"] -> Ok(model.LeftRight)
    [_, "RL"] -> Ok(model.RightLeft)
    _ -> Error(model.Malformed(number, "a direction: TD, TB, BT, LR or RL"))
  }
}

// A line may carry several statements separated by `;`. A semicolon inside a
// quoted label or a bracket pair belongs to the label, so the split tracks
// both before it cuts.
fn split_statements(line: String) -> List(String) {
  split_loop(string.to_graphemes(line), [], 0, Unquoted, [])
  |> list.map(string.trim)
  |> list.filter(fn(statement) { statement != "" })
}

/// Recursively splits statements by semicolon while respecting quotation and brackets.
fn split_loop(
  rest: List(String),
  current: List(String),
  depth: Int,
  quoting: Quoting,
  done: List(String),
) -> List(String) {
  // Traverse graphemes checking for semicolon statement delimiters.
  case rest {
    [] -> list.reverse([string.concat(list.reverse(current)), ..done])
    [grapheme, ..more] -> {
      let kept = [grapheme, ..current]

      // Handle semicolon delimiter and quotes/bracket nesting depth.
      case grapheme, quoting {
        ";", Unquoted if depth == 0 ->
          split_loop(more, [], 0, Unquoted, [
            string.concat(list.reverse(current)),
            ..done
          ])
        "\"", Quoted -> split_loop(more, kept, depth, Unquoted, done)
        "\"", Unquoted -> split_loop(more, kept, depth, Quoted, done)
        "[", Unquoted | "(", Unquoted | "{", Unquoted ->
          split_loop(more, kept, depth + 1, quoting, done)
        "]", Unquoted | ")", Unquoted | "}", Unquoted ->
          split_loop(more, kept, int.max(0, depth - 1), quoting, done)
        _, _ -> split_loop(more, kept, depth, quoting, done)
      }
    }
  }
}

/// Parses a single flowchart statement.
fn parse_statement(
  builder: FlowBuilder,
  statement: String,
  line: Int,
) -> Result(FlowBuilder, Refusal) {
  // Extract first word to check for unsupported flowchart keywords.
  let first = case words(statement) {
    [word, ..] -> word
    [] -> ""
  }

  // Reject reserved statements or parse node/edge chain.
  case list.contains(flow_keywords, first) {
    True -> Error(model.Unsupported("`" <> first <> "` statement"))
    False -> {
      use #(builder, sources, rest) <- result.try(parse_group(
        builder,
        statement,
        line,
      ))
      parse_chain(builder, sources, rest, line)
    }
  }
}

/// One `A & B` group: one or more nodes that share the edge on their side.
fn parse_group(
  builder: FlowBuilder,
  text: String,
  line: Int,
) -> Result(#(FlowBuilder, List(Int), String), Refusal) {
  use #(builder, first, rest) <- result.try(parse_node(builder, text, line))

  // Check for following ampersand indicating joint node group.
  case string.trim_start(rest) {
    "&" <> more -> {
      use #(builder, others, rest) <- result.try(parse_group(
        builder,
        string.trim_start(more),
        line,
      ))
      Ok(#(builder, [first, ..others], rest))
    }
    other -> Ok(#(builder, [first], other))
  }
}

/// Reads `edge group` pairs until the statement ends, so `A --> B --> C` adds
/// two edges and `A & B --> C` adds two from one pair of groups.
fn parse_chain(
  builder: FlowBuilder,
  sources: List(Int),
  text: String,
  line: Int,
) -> Result(FlowBuilder, Refusal) {
  // Stop parsing chain if remaining text is empty.
  case string.trim_start(text) {
    "" -> Ok(builder)
    remaining -> {
      use #(stroke, tip, infix, rest) <- result.try(parse_edge(remaining, line))
      use #(label, rest) <- result.try(pipe_label(infix, rest, line))
      use #(builder, targets, rest) <- result.try(parse_group(
        builder,
        string.trim_start(rest),
        line,
      ))
      use builder <- result.try(add_edges(
        builder,
        sources,
        targets,
        stroke,
        tip,
        label,
      ))
      parse_chain(builder, targets, rest, line)
    }
  }
}

/// Adds edges connecting all source nodes to all target nodes in a group.
fn add_edges(
  builder: FlowBuilder,
  sources: List(Int),
  targets: List(Int),
  stroke: Stroke,
  tip: Tip,
  label: String,
) -> Result(FlowBuilder, Refusal) {
  let pairs =
    list.flat_map(sources, fn(from) {
      list.map(targets, fn(to) { #(from, to) })
    })
  list.try_fold(pairs, builder, fn(builder, pair) {
    let #(from, to) = pair

    // Enforce self-loop and edge count constraints.
    case from == to, builder.edge_count >= model.max_edges {
      True, _ -> Error(model.Unsupported("self-loop edge"))
      _, True -> Error(model.TooLarge(model.Edges))
      False, False ->
        Ok(
          FlowBuilder(
            ..builder,
            edges: [
              model.Edge(from:, to:, stroke:, tip:, label:),
              ..builder.edges
            ],
            edge_count: builder.edge_count + 1,
          ),
        )
    }
  })
}

/// An edge operator, with the label of the `-- text -->` form if it had one.
/// The longer spellings come first because they begin with the shorter ones.
fn parse_edge(
  text: String,
  line: Int,
) -> Result(#(Stroke, Tip, String, String), Refusal) {
  case text {
    "<" <> _ -> Error(model.Unsupported("bidirectional edge"))
    "-.->" <> rest -> Ok(#(model.Dotted, model.Arrow, "", rest))
    "-.-" <> rest -> Ok(#(model.Dotted, model.Open, "", rest))
    "-. " <> rest -> infix_edge(rest, model.Dotted, ".->", ".-", line)
    "==>" <> rest -> Ok(#(model.Thick, model.Arrow, "", rest))
    "===" <> rest -> Ok(#(model.Thick, model.Open, "", rest))
    "== " <> rest -> infix_edge(rest, model.Thick, "==>", "===", line)
    "-->" <> rest -> Ok(#(model.Solid, model.Arrow, "", rest))
    "---" <> rest -> Ok(#(model.Solid, model.Open, "", rest))
    "-- " <> rest -> infix_edge(rest, model.Solid, "-->", "---", line)
    "--x" <> _ | "--o" <> _ -> Error(model.Unsupported("edge end marker"))
    _ -> Error(model.Malformed(line, "an edge such as -->"))
  }
}

/// The `-- text -->` form: the label runs to whichever closing operator comes
/// first, and which one it is decides whether the edge has an arrowhead.
fn infix_edge(
  rest: String,
  stroke: Stroke,
  arrow_end: String,
  open_end: String,
  line: Int,
) -> Result(#(Stroke, Tip, String, String), Refusal) {
  let arrow = string.split_once(rest, arrow_end)
  let open = string.split_once(rest, open_end)

  // Choose whichever closing operator appears first in label text.
  let found = case arrow, open {
    Ok(#(before, after)), Ok(#(other, _)) ->
      case string.length(before) <= string.length(other) {
        True -> Ok(#(before, model.Arrow, after))
        False -> Ok(#(other, model.Open, drop_open(rest, other, open_end)))
      }
    Ok(#(before, after)), Error(_) -> Ok(#(before, model.Arrow, after))
    Error(_), Ok(#(before, after)) -> Ok(#(before, model.Open, after))
    Error(_), Error(_) ->
      Error(model.Malformed(line, "the end of the edge label"))
  }

  use #(label_text, tip, after) <- result.try(found)
  use label <- result.try(edge_label(label_text))
  Ok(#(stroke, tip, label, after))
}

// The text after an open-ended operator found second. It is recomputed from
// the original text so the arrow branch never needs the split it did not use.
fn drop_open(rest: String, before: String, open_end: String) -> String {
  string.drop_start(rest, string.length(before) + string.length(open_end))
}

/// A `|label|` directly after the operator. An infix label already read wins,
/// and Mermaid does not allow both.
fn pipe_label(
  infix: String,
  text: String,
  line: Int,
) -> Result(#(String, String), Refusal) {
  case string.trim_start(text) {
    "|" <> after ->
      case string.split_once(after, "|") {
        Ok(#(inner, rest)) -> {
          use label <- result.try(edge_label(inner))
          Ok(#(label, rest))
        }
        Error(_) ->
          Error(model.Malformed(line, "a closing | for the edge label"))
      }
    _ -> Ok(#(infix, text))
  }
}

/// One node reference with its optional shape. A node already seen keeps its
/// label unless this reference gives a new one, as Mermaid does.
fn parse_node(
  builder: FlowBuilder,
  text: String,
  line: Int,
) -> Result(#(FlowBuilder, Int, String), Refusal) {
  let #(id, rest) = take_id(text)

  // Check if identifier is empty or parse node shape.
  case id {
    "" -> Error(model.Malformed(line, "a node identifier"))
    _ -> {
      use shaped <- result.try(parse_shape(rest, line))

      // Register node with or without shape delimiters.
      case shaped {
        None -> {
          use #(builder, position) <- result.try(declare(builder, id, None))
          Ok(#(builder, position, rest))
        }
        Some(#(shape, label, rest)) -> {
          use lines <- result.try(node_lines(label, id))
          use #(builder, position) <- result.try(declare(
            builder,
            id,
            Some(#(lines, shape)),
          ))
          Ok(#(builder, position, rest))
        }
      }
    }
  }
}

/// The shape delimiters directly after an identifier. Shapes this renderer
/// has no box for are refused by name rather than read as a rectangle.
fn parse_shape(
  rest: String,
  line: Int,
) -> Result(Option(#(Shape, String, String)), Refusal) {
  case rest {
    "([" <> inner -> delimited(inner, "])", model.Rounded, line)
    "[[" <> _ | "[(" <> _ | "[/" <> _ | "[\\" <> _ | "((" <> _ | "{{" <> _ ->
      Error(model.Unsupported("node shape"))
    ">" <> _ -> Error(model.Unsupported("node shape"))
    "[" <> inner -> delimited(inner, "]", model.Rectangle, line)
    "(" <> inner -> delimited(inner, ")", model.Rounded, line)
    "{" <> inner -> delimited(inner, "}", model.Decision, line)
    ":::" <> _ -> Error(model.Unsupported("class shorthand"))
    _ -> Ok(None)
  }
}

/// Text up to the closing delimiter. A quoted label may hold the delimiter, so
/// the quote is matched first and the delimiter must follow it.
fn delimited(
  inner: String,
  close: String,
  shape: Shape,
  line: Int,
) -> Result(Option(#(Shape, String, String)), Refusal) {
  // Split quoted or unquoted delimiter content.
  let split = case inner {
    "\"" <> quoted ->
      case string.split_once(quoted, "\"") {
        Ok(#(text, after)) ->
          case string.starts_with(after, close) {
            True -> Ok(#(text, string.drop_start(after, string.length(close))))
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    _ -> string.split_once(inner, close)
  }

  // Validate that closing delimiter was found.
  case split {
    Ok(#(text, after)) -> Ok(Some(#(shape, text, after)))
    Error(_) -> Error(model.Malformed(line, "a closing " <> close))
  }
}

/// Registers or updates a node. The node limit is enforced here, at the one
/// place a node can be created.
fn declare(
  builder: FlowBuilder,
  id: String,
  given: Option(#(List(String), Shape)),
) -> Result(#(FlowBuilder, Int), Refusal) {
  // Check if node exists and update label/shape accordingly.
  case dict.get(builder.index, id), given {
    Ok(position), None -> Ok(#(builder, position))
    Ok(position), Some(#(lines, shape)) ->
      Ok(#(
        FlowBuilder(
          ..builder,
          nodes: dict.insert(
            builder.nodes,
            position,
            model.Node(id:, lines:, shape:),
          ),
        ),
        position,
      ))
    Error(_), _ if builder.count >= model.max_nodes ->
      Error(model.TooLarge(model.Nodes))
    Error(_), _ -> {
      let #(lines, shape) = option.unwrap(given, #([id], model.Rectangle))
      let position = builder.count
      Ok(#(
        FlowBuilder(
          ..builder,
          nodes: dict.insert(
            builder.nodes,
            position,
            model.Node(id:, lines:, shape:),
          ),
          index: dict.insert(builder.index, id, position),
          count: position + 1,
        ),
        position,
      ))
    }
  }
}

fn take_id(text: String) -> #(String, String) {
  take_id_loop(text, "")
}

/// Grapheme loop reading an identifier string.
fn take_id_loop(rest: String, taken: String) -> #(String, String) {
  case string.pop_grapheme(rest) {
    Ok(#(grapheme, more)) ->
      case string.contains(id_alphabet, grapheme) {
        True -> take_id_loop(more, taken <> grapheme)
        False -> #(taken, rest)
      }
    Error(_) -> #(taken, rest)
  }
}

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

/// A node label: `<br>` breaks a line, multi-word lines longer than
/// `max_label_cells` wrap at spaces, every resulting line is measured, and an
/// empty label falls back to the identifier so the box is never blank.
fn node_lines(label: String, id: String) -> Result(List(String), Refusal) {
  let lines =
    label
    |> break_lines
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" })
    |> list.flat_map(wrap_words(_, model.max_label_cells))
  use _ <- result.try(list.try_each(lines, check_label))

  // Fall back to identifier if lines list is empty.
  case lines {
    [] -> Ok([id])
    _ -> Ok(lines)
  }
}

// An edge label is one line: a `<br>` in it reads as a space.
fn edge_label(text: String) -> Result(String, Refusal) {
  let label = clean_inline_label(text)
  use _ <- result.try(check_label(label))
  Ok(label)
}

/// A sequence participant, message or note label: multi-word text longer than
/// `max_label_cells` wraps at spaces across at most `max_sequence_label_lines`
/// lines, while a single unbreakable token past `max_label_cells` is still
/// refused.
const max_sequence_label_lines = 4

/// Validates and wraps a sequence diagram label.
fn sequence_label(text: String) -> Result(String, Refusal) {
  let label = clean_inline_label(text)
  let lines = wrap_words(label, model.max_label_cells)
  use _ <- result.try(list.try_each(lines, check_label))

  // Validate that label line count stays within bounds.
  case list.drop(lines, max_sequence_label_lines) {
    [] -> Ok(label)
    [_, ..] -> Error(model.TooLarge(model.LabelCells))
  }
}

/// Cleans inline label text by trimming, unquoting, and collapsing `<br>` tags.
fn clean_inline_label(text: String) -> String {
  text
  |> string.trim
  |> unquote
  |> string.replace("<br/>", " ")
  |> string.replace("<br />", " ")
  |> string.replace("<br>", " ")
  |> string.trim
}

/// Wraps a single line at spaces so multi-word labels fit within `limit` cells
/// per line. A single word wider than `limit` is kept intact on its own line
/// so `check_label` can refuse an unbreakable oversized token.
pub fn wrap_words(line: String, limit: Int) -> List(String) {
  case text.cell_width(line) <= limit {
    True -> [line]
    False ->
      case words(line) {
        [] -> [line]
        [first, ..rest] -> wrap_words_loop(rest, first, [], limit)
      }
  }
}

/// Loop for wrapping words to line budget.
fn wrap_words_loop(
  rest: List(String),
  current: String,
  done: List(String),
  limit: Int,
) -> List(String) {
  // Traverse words packing them into current line until limit is reached.
  case rest {
    [] -> list.reverse([current, ..done])
    [word, ..more] -> {
      let candidate = current <> " " <> word

      // Check if word fits on current line.
      case text.cell_width(candidate) <= limit {
        True -> wrap_words_loop(more, candidate, done, limit)
        False -> wrap_words_loop(more, word, [current, ..done], limit)
      }
    }
  }
}

/// Strips outer quotes from a string if balanced.
fn unquote(text: String) -> String {
  case text {
    "\"" <> rest ->
      case string.ends_with(rest, "\"") {
        True -> string.drop_end(rest, 1)
        False -> text
      }
    _ -> text
  }
}

/// Replaces HTML line breaks with newlines.
fn break_lines(label: String) -> String {
  label
  |> unquote
  |> string.replace("<br/>", "\n")
  |> string.replace("<br />", "\n")
  |> string.replace("<br>", "\n")
}

/// A label line must fit in the limit and be fully measurable. A zero-width
/// grapheme is a control character or a lone combining mark, and a cluster of
/// several codepoints (a base with a combining mark, an emoji joined with a
/// zero-width joiner) is drawn at a width that differs between terminals. A box
/// cannot be sized around either reliably, so both are refused. The one
/// multi-codepoint cluster accepted is a base with a variation selector, whose
/// width the terminal width function already accounts for. A bidirectional
/// format character is refused too: it has no width of its own but reorders the
/// text around it, so a box drawn beside it would not line up. The live path
/// strips them already, and this covers callers that render directly.
fn check_label(label: String) -> Result(Nil, Refusal) {
  let unmeasurable =
    list.any(string.to_graphemes(label), fn(grapheme) {
      let points =
        list.map(
          string.to_utf_codepoints(grapheme),
          string.utf_codepoint_to_int,
        )

      // Check bidi format characters or zero-width codepoints.
      case list.any(points, is_bidi_format) {
        True -> True
        False ->
          case points {
            [_, 0xFE0F] | [_, 0xFE0E] -> False
            [_] -> text.grapheme_cell_width(grapheme) == 0
            _ -> True
          }
      }
    })

  // Enforce unmeasurable and max-cell bounds.
  case unmeasurable, text.cell_width(label) > model.max_label_cells {
    True, _ -> Error(model.Unmeasurable(label))
    False, True -> Error(model.TooLarge(model.LabelCells))
    False, False -> Ok(Nil)
  }
}

/// The Arabic letter mark, the left and right marks, the embedding and override
/// controls, and the isolates.
fn is_bidi_format(point: Int) -> Bool {
  point == 0x061C
  || point == 0x200E
  || point == 0x200F
  || { point >= 0x202A && point <= 0x202E }
  || { point >= 0x2066 && point <= 0x2069 }
}

// ---------------------------------------------------------------------------
// Sequence diagrams
// ---------------------------------------------------------------------------

/// Parses a sequence diagram from numbered lines.
fn parse_sequence(rest: List(Numbered)) -> Result(Sequence, Refusal) {
  let start =
    SeqBuilder(
      people: dict.new(),
      index: dict.new(),
      count: 0,
      events: [],
      event_count: 0,
    )
  use built <- result.try(
    list.try_fold(rest, start, fn(builder, entry) {
      sequence_line(builder, entry.1, entry.0)
    }),
  )

  // Validate that at least one participant was declared.
  case built.count {
    0 -> Error(model.Malformed(1, "at least one participant"))
    _ ->
      Ok(model.Sequence(
        participants: model.indices(built.count)
          |> list.filter_map(fn(position) { dict.get(built.people, position) }),
        events: list.reverse(built.events),
      ))
  }
}

/// Parses one sequence diagram line into builder state.
fn sequence_line(
  builder: SeqBuilder,
  text: String,
  line: Int,
) -> Result(SeqBuilder, Refusal) {
  // Extract first word on the sequence line.
  let first = case words(text) {
    [word, ..] -> word
    [] -> ""
  }

  // Dispatch sequence statement according to leading keyword.
  case first {
    "participant" | "actor" ->
      parse_participant(
        builder,
        string.drop_start(text, string.length(first)),
        line,
      )
    "Note" | "note" ->
      parse_note(builder, string.drop_start(text, string.length(first)), line)
    _ ->
      case list.contains(sequence_keywords, first) {
        True ->
          Error(model.Unsupported("`" <> first <> "` in a sequence diagram"))
        False -> parse_message(builder, text, line)
      }
  }
}

/// `participant A` or `participant A as Alice`. A participant first seen in a
/// message keeps the identifier as its label until a declaration renames it.
fn parse_participant(
  builder: SeqBuilder,
  text: String,
  line: Int,
) -> Result(SeqBuilder, Refusal) {
  // Split alias clause if present.
  let #(id, label) = case string.split_once(text, " as ") {
    Ok(#(id, label)) -> #(string.trim(id), Some(string.trim(label)))
    Error(_) -> #(string.trim(text), None)
  }

  // Validate identifier format.
  case id == "" || string.contains(id, " ") {
    True -> Error(model.Malformed(line, "a participant name without spaces"))
    False -> {
      // Resolve optional label text into a sequence label.
      let label_res = case label {
        Some(value) -> sequence_label(value) |> result.map(Some)
        None -> Ok(None)
      }

      use label <- result.try(label_res)
      use #(builder, _) <- result.map(participant(builder, id, label))
      builder
    }
  }
}

/// Finds a participant by identifier, creating it on first sight.
fn participant(
  builder: SeqBuilder,
  id: String,
  label: Option(String),
) -> Result(#(SeqBuilder, Int), Refusal) {
  use _ <- result.try(check_label(id))

  // Update existing participant or insert a new one.
  case dict.get(builder.index, id) {
    Ok(position) -> {
      // Rename participant if label is explicitly provided.
      let renamed = case label {
        Some(value) ->
          dict.insert(
            builder.people,
            position,
            model.Participant(id:, label: value),
          )
        None -> builder.people
      }

      Ok(#(SeqBuilder(..builder, people: renamed), position))
    }
    Error(_) if builder.count >= model.max_nodes ->
      Error(model.TooLarge(model.Nodes))
    Error(_) -> {
      let position = builder.count
      Ok(#(
        SeqBuilder(
          ..builder,
          people: dict.insert(
            builder.people,
            position,
            model.Participant(id:, label: option.unwrap(label, id)),
          ),
          index: dict.insert(builder.index, id, position),
          count: position + 1,
        ),
        position,
      ))
    }
  }
}

/// `Note over A,B: text`, `Note left of A: text` or `Note right of A: text`.
fn parse_note(
  builder: SeqBuilder,
  text: String,
  line: Int,
) -> Result(SeqBuilder, Refusal) {
  // Split note placement prefix from body text.
  let #(place_text, body) = case string.split_once(text, ":") {
    Ok(#(place, body)) -> #(string.trim(place), string.trim(body))
    Error(_) -> #(string.trim(text), "")
  }

  use label <- result.try(sequence_label(body))

  // Parse note placement target.
  case place_text {
    "over " <> names -> {
      use #(builder, found) <- result.try(
        list.try_fold(string.split(names, ","), #(builder, []), fn(state, name) {
          let #(builder, found) = state
          use #(builder, position) <- result.map(participant(
            builder,
            string.trim(name),
            None,
          ))
          #(builder, [position, ..found])
        }),
      )
      let sorted = list.sort(found, int.compare)

      // Connect endpoints across target participants.
      case sorted, list.last(sorted) {
        [low, ..], Ok(high) ->
          add_event(builder, model.Noted(model.Over(low, high), label))
        _, _ -> Error(model.Malformed(line, "a participant after over"))
      }
    }
    "left of " <> name -> side_note(builder, name, model.LeftOf, label)
    "right of " <> name -> side_note(builder, name, model.RightOf, label)
    _ -> Error(model.Malformed(line, "Note over, left of or right of"))
  }
}

/// Attaches a single-sided note to a participant.
fn side_note(
  builder: SeqBuilder,
  name: String,
  place: fn(Int) -> NotePlace,
  label: String,
) -> Result(SeqBuilder, Refusal) {
  use #(builder, position) <- result.try(participant(
    builder,
    string.trim(name),
    None,
  ))
  add_event(builder, model.Noted(place(position), label))
}

/// Appends an event to the sequence builder, enforcing event count limits.
fn add_event(builder: SeqBuilder, event: Event) -> Result(SeqBuilder, Refusal) {
  case builder.event_count >= model.max_edges {
    True -> Error(model.TooLarge(model.Edges))
    False ->
      Ok(
        SeqBuilder(
          ..builder,
          events: [event, ..builder.events],
          event_count: builder.event_count + 1,
        ),
      )
  }
}

// The message operators, longest first so `-->>` is not read as `-->` with a
// stray `>`.
const message_operators = [
  #("-->>", model.Dotted, model.Head),
  #("->>", model.Solid, model.Head),
  #("--x", model.Dotted, model.Cross),
  #("-x", model.Solid, model.Cross),
  #("-->", model.Dotted, model.Plain),
  #("->", model.Solid, model.Plain),
]

/// `A->>B: text`. The operator is the earliest one in the part before the
/// colon, so an identifier is any text up to it.
fn parse_message(
  builder: SeqBuilder,
  text: String,
  line: Int,
) -> Result(SeqBuilder, Refusal) {
  // Split message text from payload at colon.
  let #(head, body) = case string.split_once(text, ":") {
    Ok(#(head, body)) -> #(head, string.trim(body))
    Error(_) -> #(text, "")
  }

  // Find message arrow operator in the header.
  case find_operator(head) {
    None -> Error(model.Malformed(line, "a message such as A->>B: text"))
    Some(#(position, operator, stroke, end)) -> {
      let source = string.trim(string.slice(head, 0, position))
      let target =
        string.trim(string.drop_start(head, position + string.length(operator)))
      message_between(builder, source, target, stroke, end, body, line)
    }
  }
}

/// Adds a message event between two participant endpoints.
fn message_between(
  builder: SeqBuilder,
  source: String,
  target: String,
  stroke: Stroke,
  end: MessageEnd,
  body: String,
  line: Int,
) -> Result(SeqBuilder, Refusal) {
  case has_bracket(source, target), source, target {
    _, "", _ | _, _, "" -> Error(model.Malformed(line, "two participants"))

    // `A<<->>B` is a message in both directions. The earliest operator in it
    // is the right-hand arrow, which would leave `A<<` as a participant and
    // draw a one-way message, so a name holding an arrow bracket is refused.
    True, _, _ -> Error(model.Unsupported("bidirectional message"))
    _, _, "+" <> _ | _, _, "-" <> _ ->
      Error(model.Unsupported("message activation"))
    _, _, _ -> {
      use text <- result.try(sequence_label(body))
      use #(builder, from) <- result.try(participant(builder, source, None))
      use #(builder, to) <- result.try(participant(builder, target, None))
      add_event(
        builder,
        model.Said(model.Message(from:, to:, stroke:, end:, text:)),
      )
    }
  }
}

fn has_bracket(source: String, target: String) -> Bool {
  string.contains(source, "<")
  || string.contains(source, ">")
  || string.contains(target, "<")
  || string.contains(target, ">")
}

/// The earliest operator in the part before the colon, and where it starts.
/// Each operator is searched for once, so the work is the line's length times
/// the six operators and not its square. The list is longest first and a later
/// operator only wins by starting strictly earlier, so at one position the
/// longest spelling is the one read.
fn find_operator(head: String) -> Option(#(Int, String, Stroke, MessageEnd)) {
  list.fold(message_operators, None, fn(best, candidate) {
    let #(operator, stroke, end) = candidate

    // Compare candidate position against earliest match.
    case string.split_once(head, operator), best {
      Error(_), _ -> best
      Ok(#(before, _)), Some(#(known, _, _, _)) ->
        case string.length(before) < known {
          True -> Some(#(string.length(before), operator, stroke, end))
          False -> best
        }
      Ok(#(before, _)), None ->
        Some(#(string.length(before), operator, stroke, end))
    }
  })
}

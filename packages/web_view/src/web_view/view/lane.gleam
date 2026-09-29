//// The transcript lane: the page strand's turns, drawn between the agent
//// strip and the page's bottom bar or dock on both pages.
////
//// The component projects a capture once into `turns.Piece`s
//// (`component.relaned`), and this module only draws them. How the lines
//// fold into turns, which rows a capture becomes and what each line says
//// are `session_view`'s. Nothing here decides anything about the session.
////
//// Almost every string this region draws was written by the session: a
//// prompt, an answer, a tool's output, a child's report, a peer's message.
//// Each reaches the page only as a text node, directly or through
//// `markdown_view`, which keeps the same rule for rendered Markdown. No
//// attribute, class, handler or key is ever built from session text: a
//// piece is keyed by the engine's identity for it, and a hue comes from a
//// strand's position, never its name. Nothing here uses `unsafe_raw_html`.
////
//// Every transcript line and card body is drawn inside its own memo whose
//// one dependency is that line or body, with no memo around them. `view`
//// says why the memos have to be the leaves; `lane_memo_test` counts the
//// lines a render draws, and a change here must leave its counts as they
//// are.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/agent_roster
import session_view/markdown
import session_view/transcript_line.{type Line}
import session_view/transcript_lines
import session_view/turns
import web_view/markdown_view
import web_view/view/strip

/// The lane: the page strand's turns, keyed by the engine's identity for
/// each piece, with every transcript line and every card body drawn inside
/// a memo whose one dependency is that line or body. A capture draws only
/// what is new: a line equal to the one its memo drew from reuses the
/// element it drew, so its Markdown is not parsed again. The pieces, the
/// turns' folds and the blocks around the lines are rebuilt on each render,
/// which costs little. A window that drops its oldest rows removes them
/// rather than rewriting the rows after them.
///
/// The memos are the leaves, with no memo around them, and that is what
/// makes them hold. Lustre 5.7.1 keeps a render's memo elements in a table
/// it starts afresh on each render (`lustre/vdom/cache.tick`). A memo whose
/// dependencies are unchanged carries only its own element into the new
/// table (`cache.keep_memo`), not the memos nested inside that element. So
/// a render in which an enclosing memo hit would drop the entries of every
/// memo inside it, and the next render that changed the enclosing one would
/// draw and parse every line again. A turn's work is one piece that changes
/// whenever an answer moves into it, which is why the memos are per line and
/// not per piece. Every render visits each line's memo and carries each hit
/// forward, at the cost of comparing each line with the one it was drawn
/// from; Lustre compares dependencies with `==` on the BEAM.
///
/// The lane is drawn inside a `<loom-follow>` (`packages/web_client`),
/// which is the transcript's scroll container (the page's frame is pinned
/// around it). It scrolls to a row that lands below its view while the
/// reader is at the bottom, and stops once they scroll up to read. Where
/// the reader has scrolled is the browser's to know: the server never
/// renders it, so scrolling costs no message here.
///
/// Above the oldest row the lane says what lies before it (`Top`). The page
/// holds only the newest rows of the strand, so older ones may exist that
/// it does not draw. When they do, the lane draws a "Load older" button
/// that sends `load`. Both pages draw it, and on an observer's page it is
/// the one handler the view attaches (protocol-change/051, the addendum on
/// history paging), so `load` must ask for a read and nothing else.
///
/// ## Examples
///
/// ```gleam
/// // lane.view(component.pieces(model), component.top(model), OlderRequested)
/// ```
pub fn view(
  pieces: List(turns.Piece),
  top: Top,
  load: message,
) -> Element(message) {
  rows(pieces, boundary(top, load), line_element)
}

/// What lies above the oldest row the page holds.
pub type Top {
  /// The page holds the strand's first row: there is nothing older.
  Beginning

  /// Older rows exist, and the page can load them.
  Earlier

  /// A read for older rows is outstanding.
  Loading

  /// Older rows exist, but the page already holds `rows`, its limit, and
  /// loads no more.
  Full(rows: Int)
}

/// The attribute that marks the "Load older" button, so `<loom-follow>`
/// can tell a press of it from any other click in the lane and keep the
/// reader's place while the older rows arrive above it. Its value is fixed
/// here and never comes from the session.
pub const older_marker = "loom-older"

/// `view` with the boundary above the oldest row and the drawing of a
/// transcript line supplied, so a test can count the lines a render draws.
/// `draw` must depend on nothing but the line it is given, because the
/// line's memo depends on the line alone.
///
/// The boundary is the first child of `<loom-follow>` and the rows are the
/// second, whatever the boundary says, so the lane's own path does not move
/// when the boundary changes from a button to a line of text.
///
/// ## Examples
///
/// ```gleam
/// // lane.rows(pieces, element.none(), fn(line) { html.text(line.text) })
/// ```
@internal
pub fn rows(
  pieces: List(turns.Piece),
  top: Element(message),
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  element.element("loom-follow", [attribute.class("follow")], [
    top,
    keyed.div(
      [attribute.class("transcript lane"), attribute.role("log")],
      list.map(pieces, fn(piece) {
        #(piece_key(piece), piece_element(piece, draw))
      }),
    ),
  ])
}

// The line above the oldest row. Every word is fixed here; only the row
// limit is a number, and it is the component's constant.
//
// The button is a real button with its label as its text. It carries the
// marker `<loom-follow>` listens for, and its handler is the page's read.
// It is the first child of the first child of `<loom-follow>`, which is the
// path the page socket admits an observer's click at
// (`component.older_path`).
fn boundary(top: Top, load: message) -> Element(message) {
  html.div([attribute.class("lane-top")], [
    case top {
      Beginning ->
        html.p([attribute.class("lane-boundary")], [
          html.text("Beginning of this conversation."),
        ])
      Earlier ->
        html.button(
          [
            attribute.type_("button"),
            attribute.class("load-older"),
            attribute.data(older_marker, "load"),
            event.on_click(load),
          ],
          [html.text("Load older")],
        )
      Loading ->
        html.p([attribute.class("lane-boundary")], [
          html.text("Loading older rows…"),
        ])
      Full(rows:) ->
        html.p([attribute.class("lane-boundary")], [
          html.text(
            "This page holds at most "
            <> int.to_string(rows)
            <> " rows, so it loads no older ones.",
          ),
        ])
    },
  ])
}

// One transcript line, drawn once and kept while the line is unchanged.
fn line_row(
  line: Line,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  element.memo([element.ref(line)], fn() { draw(line) })
}

fn piece_key(piece: turns.Piece) -> String {
  case piece {
    turns.Plain(block:, ..) | turns.Commentary(block:) -> block.key
    turns.Work(key:, ..)
    | turns.Spawned(key:, ..)
    | turns.Returned(key:, ..)
    | turns.Nudged(key:, ..)
    | turns.Peer(key:, ..)
    | turns.Missed(key:, ..) -> key
  }
}

fn piece_element(
  piece: turns.Piece,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  case piece {
    turns.Plain(block:, thoughts:) -> block_element(block, thoughts, draw)

    // A settled turn's work is a `<loom-fold>` (`packages/web_client`),
    // collapsed until the reader opens it. The fold opens and closes in the
    // browser, so it needs no handler here and works on an observer's page,
    // and the server never renders its state, so a later patch leaves the
    // reader's choice alone. Every word in it is a child the server renders
    // and escapes: the divider in the `summary` slot, the work in the
    // default one.
    turns.Work(worked:, items:, folding: turns.Folded, ..) ->
      element.element("loom-fold", [attribute.class("work")], [
        html.span(
          [
            attribute.attribute("slot", "summary"),
            attribute.class("work-divider"),
          ],
          [html.text(turns.divider(worked))],
        ),
        keyed.div([attribute.class("work-items")], work_items(items, draw)),
      ])

    // The turn still running is drawn open, with no divider to fold it.
    turns.Work(items:, folding: turns.Open, ..) ->
      keyed.div([attribute.class("work open")], work_items(items, draw))

    turns.Spawned(child:, purpose:, hue:, standing:, ..) ->
      html.div([attribute.class("spawn"), strip.hue_class(hue)], [
        html.span([attribute.class("spawn-head")], [
          html.text(
            "↳ agent_spawn · "
            <> case child {
              Some(child) -> "sub:" <> agent_roster.short_name(child)
              None -> standing_text(standing)
            },
          ),
        ]),
        html.span([attribute.class("spawn-purpose")], [html.text(purpose)]),
      ])

    turns.Returned(child:, outcome:, report:, hue:, ..) ->
      html.article([attribute.class("result-card"), strip.hue_class(hue)], [
        html.p([attribute.class("card-head")], [
          html.text(
            "from sub:"
            <> agent_roster.short_name(child)
            <> " · result · "
            <> outcome,
          ),
        ]),
        card_body(report),
      ])

    turns.Nudged(frame:, body:, ..) ->
      html.article([attribute.class("nudge")], [
        html.p([attribute.class("card-head")], [
          html.text(case frame {
            turns.Nudges -> "advisor · nudge · delivered"
            turns.Advice -> "advisor · advice · delivered"
          }),
        ]),
        card_body(body),
      ])

    // Another session's message. The daemon records that it was stored and
    // nothing about whether anyone read it, so the receipt says `stored`.
    turns.Peer(session:, strand:, text:, ..) ->
      html.article([attribute.class("peer-card")], [
        html.p([attribute.class("card-head")], [
          html.span([attribute.class("peer-from")], [
            html.text("peer · " <> session <> " · " <> strand),
          ]),
          html.span([attribute.class("receipt")], [html.text("stored")]),
        ]),
        card_body(text),
      ])

    turns.Missed(text:, ..) ->
      html.p([attribute.class("cache-miss")], [html.text(text)])

    // The advisor's own commentary, captured on its strand and not sent to
    // the primary: drawn as the transcript draws it, in the advisor's
    // colour, so it cannot pass for the primary's words.
    turns.Commentary(block:) ->
      html.div(
        [attribute.class("block"), attribute.class("commentary")],
        list.map(block.rows, fn(row) { line_row(row.1, draw) }),
      )
  }
}

// A card's body, parsed when it is first drawn and kept by its memo while
// it is unchanged, as a transcript line is (`rows`).
fn card_body(body: String) -> Element(message) {
  use <- element.memo([element.ref(body)])
  html.div(
    [attribute.class("card-body"), attribute.class("markdown")],
    markdown_view.blocks(markdown.parse(body)),
  )
}

// A turn's items, keyed by their blocks and calls. The window drops its
// oldest rows as new ones arrive, so a turn's first items leave while the
// rest stay; keyed, the items that stay are matched to themselves and their
// line memos hold, where unkeyed every item would be compared with its
// neighbour and every line drawn again.
fn work_items(
  items: List(turns.Item),
  draw: fn(Line) -> Element(message),
) -> List(#(String, Element(message))) {
  list.map(items, fn(item) {
    let key = case item {
      turns.Narrated(block:, ..) -> block.key
      turns.Step(key:, ..) -> key
    }
    #(key, item_element(item, draw))
  })
}

fn item_element(
  item: turns.Item,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  case item {
    turns.Narrated(block:, thoughts:) -> block_element(block, thoughts, draw)
    turns.Step(standing:, summary:, detail:, full:, ..) ->
      html.div([attribute.class("step"), standing_class(standing)], [
        html.p([attribute.class("step-head")], [
          html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
            html.text(standing_glyph(standing)),
          ]),
          html.span([attribute.class("step-summary")], [html.text(summary)]),
          html.span([attribute.class("step-state")], [
            html.text(standing_text(standing)),
          ]),
        ]),
        ..expander(detail, full, draw)
      ])
  }
}

fn standing_class(standing: turns.Standing) -> attribute.Attribute(message) {
  case standing {
    turns.Pending -> attribute.class("pending")
    turns.Done -> attribute.class("done")
    turns.Failed -> attribute.class("failed")
  }
}

fn standing_glyph(standing: turns.Standing) -> String {
  case standing {
    turns.Pending -> "●"
    turns.Done -> "✓"
    turns.Failed -> "✕"
  }
}

fn standing_text(standing: turns.Standing) -> String {
  case standing {
    turns.Pending -> "running"
    turns.Done -> "done"
    turns.Failed -> "failed"
  }
}

// A block drawn as the transcript draws it, one line per row. The blank a
// terminal places between tool groups is spacing here, so a spacer block
// never reaches the lane. A reasoning row that has a full form
// (`thoughts`, by the row's key) is an expander of its own, so the rest of
// the block, an answer beside the reasoning, is not drawn twice.
fn block_element(
  block: transcript_lines.Block,
  thoughts: Dict(String, List(Line)),
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  html.div(
    [attribute.class("block")],
    list.flat_map(block.rows, fn(row) {
      case dict.get(thoughts, row.0) {
        Ok(full) -> expander([row.1], full, draw)
        Error(Nil) -> [line_row(row.1, draw)]
      }
    }),
  )
}

// Rows the reader may expand. With nothing more to show they are the rows,
// each in its memo. With more (`Step.full`, `Piece.Plain.thoughts`, which
// `turns` built once for the capture and the host's cap already cut), they
// are one `<loom-expand>` (`packages/web_client`) holding the compact rows
// in its `compact` slot and the full ones in its `full` slot. Both are the
// server's children, escaped text nodes like every other row; the element
// shows one slot at a time in the browser, so opening it costs no message,
// and the server never renders which is open. The full rows are memoized
// per line as the compact ones are, so an unchanged call draws nothing
// again.
fn expander(
  compact: List(Line),
  full: List(Line),
  draw: fn(Line) -> Element(message),
) -> List(Element(message)) {
  let shown = list.map(compact, line_row(_, draw))
  case full {
    [] -> shown
    [_, ..] -> [
      element.element("loom-expand", [attribute.class("expand")], [
        html.div(
          [
            attribute.attribute("slot", "compact"),
            attribute.class("expand-compact"),
          ],
          shown,
        ),
        html.div(
          [attribute.attribute("slot", "full"), attribute.class("expand-full")],
          list.map(full, line_row(_, draw)),
        ),
      ]),
    ]
  }
}

fn line_element(line: Line) -> Element(message) {
  case body_of(line.speaker) {
    Literal ->
      html.pre([attribute.class("line"), speaker_class(line.speaker)], [
        html.text(line.text),
      ])

    // The line is parsed here, when it is drawn. A line is drawn when it
    // first appears, and its memo keeps what it drew while it is unchanged
    // (`rows`), so an answer is parsed about once. Each line is its
    // own tree, so an unclosed fence ends with its line.
    Markdown -> {
      let tree = markdown.parse(line.text)
      html.div(
        [
          attribute.class("line"),
          speaker_class(line.speaker),
          attribute.class("markdown"),
        ],
        markdown_view.blocks(tree),
      )
    }
  }
}

// How a line's text is drawn: as Markdown or as it is.
type Body {
  Markdown
  Literal
}

// The speakers whose text the terminal renders as Markdown
// (`tui/render.speaker_rows`), so both hosts agree on which rows are
// formatted. Everything else, tool output above all, stays preformatted.
fn body_of(speaker: transcript_line.Speaker) -> Body {
  case speaker {
    transcript_line.Assistant
    | transcript_line.Reasoning
    | transcript_line.ToolDetail -> Markdown
    transcript_line.System
    | transcript_line.User
    | transcript_line.ReasoningDigest
    | transcript_line.SummarizedReasoning
    | transcript_line.SummarizedAdvice
    | transcript_line.ToolCall
    | transcript_line.ToolResult
    | transcript_line.ToolPatch
    | transcript_line.ToolFailure
    | transcript_line.Failure
    | transcript_line.Spacer -> Literal
  }
}

// A class per speaker, which is the whole of a line's styling here as in the
// terminal. The stylesheet decides what each looks like.
fn speaker_class(
  speaker: transcript_line.Speaker,
) -> attribute.Attribute(message) {
  case speaker {
    transcript_line.System -> attribute.class("system")
    transcript_line.User -> attribute.class("user")
    transcript_line.Assistant -> attribute.class("assistant")
    transcript_line.Reasoning -> attribute.class("reasoning")
    transcript_line.ReasoningDigest -> attribute.class("reasoning-digest")
    transcript_line.SummarizedReasoning ->
      attribute.class("summarized-reasoning")
    transcript_line.SummarizedAdvice -> attribute.class("summarized-advice")
    transcript_line.ToolCall -> attribute.class("tool-call")
    transcript_line.ToolResult -> attribute.class("tool-result")
    transcript_line.ToolDetail -> attribute.class("tool-detail")
    transcript_line.ToolPatch -> attribute.class("tool-patch")
    transcript_line.ToolFailure -> attribute.class("tool-failure")
    transcript_line.Failure -> attribute.class("failure")
    transcript_line.Spacer -> attribute.class("spacer")
  }
}

//// The transcript lane: the page strand's turns, drawn above the page's
//// bottom bar or dock on both pages, as a timeline with a dot in the hue of
//// the strand each piece belongs to.
////
//// The component projects a capture once into `turns.Piece`s
//// (`component.relaned`), and this module only draws them. How the lines
//// fold into turns, which rows a capture becomes and what each line says
//// are `session_view`'s. Nothing here decides anything about the session.
////
//// Each piece is a row of the timeline: a dot, and the piece beside it. The
//// dot is a decoration hidden from assistive technology. Where the piece
//// belongs to another strand the page lists (a spawn, a result, a nudge), the
//// dot and the strand's tag in the piece carry `data-loom-focus`, the
//// position of that strand's card, and no handler: `<loom-shell>` hears the
//// click and clicks the card, so the observer's socket admits nothing new
//// (protocol-change/051, the addendum on the marker relay). A piece of the
//// strand on screen carries no marker, since focusing the strand already
//// shown does nothing, and a strand the page does not list has none to focus.
//// The marker is a number from `strip.positions`; the strand's identity and
//// name never reach an attribute.
////
//// Almost every string this region draws was written by the session: a
//// prompt, an answer, a tool's output, a child's report, a peer's message.
//// Each reaches the page only as a text node, directly or through
//// `markdown_view`, which keeps the same rule for rendered Markdown. No
//// attribute, class, handler or key is ever built from session text: a
//// piece is keyed by the engine's identity for it, and a hue comes from a
//// strand's position, never its name. Nothing here uses `unsafe_raw_html`.
////
//// A row that carries images (a person's message, a tool's result) draws each
//// beneath its text as a thumbnail inside a `<details>`, which the browser
//// opens and closes by itself, so the thumbnail grows on a click and the page
//// hears nothing. The `src` is `web_view/image.address`: the page's own
//// session, the engine's name for the row and a position. It is the one
//// `src` the view builds, it is relative to the page, and nothing the
//// session wrote is in it (protocol-change/051, the addendum on images). An
//// image whose declared type is not a raster type draws no picture and keeps
//// its `[image <type>]` text row.
////
//// Every transcript line and card body is drawn inside its own memo whose
//// one dependency is that line or body, with no memo around them. `view`
//// says why the memos have to be the leaves; `lane_memo_test` counts the
//// lines a render draws, and a change here must leave its counts as they
//// are.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/agent_roster
import session_view/decisions
import session_view/markdown
import session_view/transcript_image.{type Image}
import session_view/transcript_line.{type Line}
import session_view/transcript_lines.{type Block}
import session_view/turns
import web_view/image
import web_view/markdown_view
import web_view/view/live
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
/// The response the provider is still writing is `live`, drawn as the last
/// entry of the lane's keyed list (`view/live`). It is keyed `live`, which no
/// piece's key can equal, so the committed row that replaces it is inserted
/// before it in the same patch that removes it, and the answer does not
/// leave the page and come back. The committed rows above it are the pieces
/// and are drawn as they were: a fragment changes `live` alone, so the diff
/// is that region and every piece's memo holds.
///
/// ## Examples
///
/// ```gleam
/// // lane.view(component.pieces(model), component.live(model), component.top(model), OlderRequested, lane.NoReplies, component.marks(model), component.session_id(model))
/// ```
pub fn view(
  pieces: List(turns.Piece),
  live: List(live.Row),
  top: Top,
  load: message,
  replies: Replies(message),
  marks: Marks,
  session: String,
) -> Element(message) {
  rows(pieces, live, boundary(top, load), line_element, replies, marks, session)
}

/// What the lane needs to mark a piece as belonging to a strand: which strand
/// is on screen and its hue, and the position of each strand the panel lists.
///
/// The positions are `strip.positions`, so a dot's marker and a card's are
/// numbered in one place. A strand with no position is not listed, and its
/// dot and tag are not controls.
pub type Marks {
  Marks(
    /// The strand on screen, whose own pieces carry no marker.
    active: String,
    /// The hue of that strand's dots.
    hue: turns.Hue,
    /// The position of each listed strand's card, by the strand's identity.
    positions: Dict(String, Int),
  )
}

/// Marks for a lane that lists no strand: every dot is decoration and no tag
/// is a control. `main` is on screen.
///
/// ## Examples
///
/// ```gleam
/// // lane.view(pieces, [], lane.Beginning, load, lane.NoReplies, lane.no_marks())
/// ```
pub fn no_marks() -> Marks {
  Marks(active: "main", hue: turns.Primary, positions: dict.new())
}

/// Whether the lane offers a reply to a peer's message, and what pressing it
/// sends.
///
/// The Reply button carries the engine's key for the piece, a sequence, and
/// never the peer's session or strand, so the handler holds nothing the
/// session wrote. The operator's page passes `Replies`, and the observer's
/// passes `NoReplies`, so an observer's lane has no handler but "Load older".
pub type Replies(message) {
  /// The lane offers no reply. An observer's page has none to send.
  NoReplies

  /// Each peer message carries a Reply button that sends this message,
  /// given the piece's key.
  ///
  /// It also carries an Open button when `open`, given the session identity
  /// the peer's message names, answers with a `Destination`. The page answers
  /// only for a session that is in the principal's own list of live sessions
  /// (`component.openable`), so a peer that names a session the principal
  /// does not hold, or one that is saved, has no button, and the button's
  /// label and message come from the catalogue and not from the peer.
  Replies(
    reply: fn(String) -> message,
    open: fn(String) -> Option(Destination(message)),
  )
}

/// Another session a peer message's card may open: the words the button
/// carries, from the catalogue, and the message pressing it sends.
pub type Destination(message) {
  Destination(
    /// The session's name in the catalogue, or its identity's first eight
    /// characters, as the sidebar calls it (`sessions.label`).
    label: String,
    /// What pressing the button sends.
    press: message,
  )
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
/// line's memo depends on the line alone. `session` is the identity the
/// images' addresses are relative to; the empty string draws no picture.
///
/// The boundary is the first child of `<loom-follow>` and the rows are the
/// second, whatever the boundary says, so the lane's own path does not move
/// when the boundary changes from a button to a line of text.
///
/// ## Examples
///
/// ```gleam
/// // lane.rows(pieces, [], element.none(), fn(line) { html.text(line.text) }, lane.NoReplies, lane.no_marks(), "")
/// ```
@internal
pub fn rows(
  pieces: List(turns.Piece),
  live: List(live.Row),
  top: Element(message),
  draw: fn(Line) -> Element(message),
  replies: Replies(message),
  marks: Marks,
  session: String,
) -> Element(message) {
  element.element("loom-follow", [attribute.class("follow")], [
    top,
    keyed.div(
      [attribute.class("transcript lane"), attribute.role("log")],
      list.append(
        list.map(pieces, fn(piece) {
          #(
            piece_key(piece),
            timeline_row(piece, draw, replies, marks, session),
          )
        }),
        live_entry(live, draw),
      ),
    ),
  ])
}

// The live region as the lane's last entry, or no entry while nothing is
// streaming. Its key is a word, and a piece's key is a sequence, so the two
// never collide.
fn live_entry(
  rows: List(live.Row),
  draw: fn(Line) -> Element(message),
) -> List(#(String, Element(message))) {
  case rows {
    [] -> []
    [_, ..] -> [#("live", live.view(rows, draw))]
  }
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
    | turns.Sibling(key:, ..)
    | turns.Missed(key:, ..)
    | turns.Decided(key:, ..) -> key
  }
}

// One row of the timeline: the dot in the hue of the strand the piece belongs
// to, and the piece. The dot is drawn for every piece so the line reads as one,
// and is a control only where the piece belongs to another strand the page
// lists. Its marker is the position of that strand's card, a number.
fn timeline_row(
  piece: turns.Piece,
  draw: fn(Line) -> Element(message),
  replies: Replies(message),
  marks: Marks,
  session: String,
) -> Element(message) {
  let #(hue, target) = belongs_to(piece, marks)
  html.div([attribute.class("tl-row"), strip.hue_class(hue)], [
    html.span(
      [attribute.class("dot"), attribute.aria_hidden(True), ..marker(target)],
      [],
    ),
    html.div([attribute.class("tl-body")], [
      piece_element(piece, draw, replies, marks, session),
    ]),
  ])
}

// The hue a piece's dot is drawn in and the card it focuses, if any. A piece
// of the strand on screen is that strand's; a spawn and a result are the
// child's; a nudge and the advisor's commentary are the advisor's; another
// session's message is nobody's here.
fn belongs_to(piece: turns.Piece, marks: Marks) -> #(turns.Hue, Option(Int)) {
  case piece {
    turns.Plain(..) | turns.Work(..) | turns.Missed(..) | turns.Decided(..) -> #(
      marks.hue,
      None,
    )
    turns.Spawned(child:, hue:, ..) -> #(
      hue,
      option.then(child, position(marks, _)),
    )
    turns.Returned(child:, hue:, ..) -> #(hue, position(marks, child))
    turns.Nudged(..) | turns.Commentary(..) -> #(
      turns.Advisor,
      position(marks, agent_roster.advisor),
    )
    turns.Peer(..) -> #(turns.Unplaced, None)
    turns.Sibling(strand:, ..) -> #(turns.Unplaced, position(marks, strand))
  }
}

// The position of a strand's card, when the strand is listed and is not the
// one on screen.
fn position(marks: Marks, strand: String) -> Option(Int) {
  case strand == marks.active {
    True -> None
    False -> option.from_result(dict.get(marks.positions, strand))
  }
}

fn marker(target: Option(Int)) -> List(attribute.Attribute(message)) {
  case target {
    Some(position) -> [strip.focus_attribute(position)]
    None -> []
  }
}

// A strand's tag in a piece: a real button carrying the marker where the
// strand can be focused, and plain text where it cannot, so the words read the
// same either way.
fn tag(label: String, target: Option(Int)) -> Element(message) {
  case target {
    Some(position) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("tag"),
          strip.focus_attribute(position),
        ],
        [html.text(label)],
      )
    None -> html.text(label)
  }
}

fn piece_element(
  piece: turns.Piece,
  draw: fn(Line) -> Element(message),
  replies: Replies(message),
  marks: Marks,
  session: String,
) -> Element(message) {
  case piece {
    turns.Plain(block:, thoughts:) ->
      block_element(block, thoughts, draw, session)

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
        keyed.div(
          [attribute.class("work-items")],
          work_items(items, draw, session),
        ),
      ])

    // The turn still running is drawn open, with no divider to fold it.
    turns.Work(items:, folding: turns.Open, ..) ->
      keyed.div(
        [attribute.class("work open")],
        work_items(items, draw, session),
      )

    turns.Spawned(child:, purpose:, hue:, standing:, ..) ->
      html.div([attribute.class("spawn"), strip.hue_class(hue)], [
        html.span([attribute.class("spawn-head")], [
          html.text("↳ agent_spawn · "),
          case child {
            Some(child) ->
              tag(
                "sub:" <> agent_roster.short_name(child),
                position(marks, child),
              )
            None -> html.text(standing_text(standing))
          },
        ]),
        html.span([attribute.class("spawn-purpose")], [html.text(purpose)]),
      ])

    turns.Returned(child:, outcome:, report:, hue:, ..) ->
      html.article([attribute.class("result-card"), strip.hue_class(hue)], [
        html.p([attribute.class("card-head")], [
          html.text("from "),
          tag("sub:" <> agent_roster.short_name(child), position(marks, child)),
          html.text(" · result · " <> outcome),
        ]),
        card_body(report),
      ])

    turns.Nudged(frame:, body:, ..) ->
      html.article([attribute.class("nudge")], [
        html.p([attribute.class("card-head")], [
          tag("advisor", position(marks, agent_roster.advisor)),
          html.text(case frame {
            turns.Nudges -> " · nudge · delivered"
            turns.Advice -> " · advice · delivered"
          }),
        ]),
        card_body(body),
      ])

    // Another session's message. The daemon records that it was stored and
    // nothing about whether anyone read it, so the receipt says `stored`.
    //
    // A page that may answer offers a Reply button after the body. The button
    // sends the piece's key and nothing the peer wrote.
    turns.Peer(key:, session:, strand:, text:) ->
      html.article([attribute.class("peer-card")], [
        html.p([attribute.class("card-head")], [
          html.span([attribute.class("peer-from")], [
            html.text("peer · " <> session <> " · " <> strand),
          ]),
          html.span([attribute.class("receipt")], [html.text("stored")]),
        ]),
        card_body(text),
        ..peer_actions(replies, key, session)
      ])

    // A strand of this same session. There is no peer link behind it, so
    // there is no receipt and no Reply button: the recipient's model answers
    // with its own `agent_send`. A brief's result-contract trailer is the
    // harness's instruction and follows the sender's words as a second body.
    turns.Sibling(strand:, text:, trailer:, ..) ->
      html.article([attribute.class("sibling-card")], [
        html.p([attribute.class("card-head")], [
          html.span([attribute.class("peer-from")], [
            html.text("strand · " <> strand),
          ]),
        ]),
        card_body(text),
        ..case trailer {
          Some(instruction) -> [card_body(instruction)]
          None -> []
        }
      ])

    turns.Missed(text:, ..) ->
      html.p([attribute.class("cache-miss")], [html.text(text)])

    // An approval decision, as the register recorded it: who answered, and
    // what. The names are the principal's and the tool's, text nodes both;
    // the class is chosen from the closed verdict.
    turns.Decided(decision:, ..) ->
      html.p(
        [
          attribute.class("decided"),
          attribute.class(case decision.verdict {
            decisions.Allowed -> "decided-allowed"
            decisions.Denied -> "decided-denied"
          }),
        ],
        [
          html.span([attribute.class("decided-who")], [
            html.text(decision.who),
          ]),
          html.text(case decision.verdict {
            decisions.Allowed -> " allowed "
            decisions.Denied -> " denied "
          }),
          html.span([attribute.class("decided-tool")], [
            html.text(case decision.tool {
              "" -> "a request"
              tool -> tool
            }),
          ]),
        ],
      )

    // The advisor's own commentary, captured on its strand and not sent to
    // the primary. The primary never saw it, so the lane keeps only its
    // hairline: the request the advisor made, in the advisor's colour,
    // one line. The dot beside it focuses the advisor's own transcript
    // through the marker relay, which is where the full bodies live, and
    // the panel's commentary section holds the same board for a reader
    // who wants it beside the strands (`view/commentary`). The words are
    // the projection's own label row, so the marker claims a request
    // only, never a delivery: the tool result may still downgrade it.
    turns.Commentary(block:) -> {
      let label = commentary_label(block)
      html.p([attribute.class("commentary-mark")], [
        tag("advisor", position(marks, agent_roster.advisor)),
        html.text(" · " <> label),
      ])
    }
  }
}

// The label the projection wrote for the advisor's request: the block's
// last `System` row. Every commentary block carries exactly one, the
// heading and the not-loaded notice aside, and the full text follows it as
// `ToolDetail`; taking the last `System` row keeps the marker honest even
// if the heading rows change. The projection's label opens with
// `Advisor · `, which the advisor's tag beside it already says, so the
// marker keeps only the words after it.
fn commentary_label(block: Block) -> String {
  block.rows
  |> list.filter_map(fn(row) {
    case row.1 {
      transcript_line.Line(transcript_line.System, text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> list.last
  |> result.map(fn(text) {
    string.split_once(text, " · ")
    |> result.map(fn(parts) { parts.1 })
    |> result.unwrap(text)
  })
  |> result.unwrap("commentary")
}

// The buttons of a peer card, or nothing on a lane that offers none. Reply is
// a real button, labelled for what it does, and puts a draft in the composer
// rather than sending anything: the operator reads it and sends it. Open is
// drawn only when the page can open the session the peer's message names
// (`Replies.open`), and asks the daemon for a page of it. The label is the
// catalogue's name for the session, a text node, and the peer's own words
// are the card's head and body, which are unchanged.
fn peer_actions(
  replies: Replies(message),
  key: String,
  session: String,
) -> List(Element(message)) {
  case replies {
    NoReplies -> []
    Replies(reply:, open:) -> [
      html.p([attribute.class("card-actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("peer-reply"),
            event.on_click(reply(key)),
          ],
          [html.text("Reply to this peer")],
        ),
        ..open_button(open(session))
      ]),
    ]
  }
}

fn open_button(
  destination: Option(Destination(message)),
) -> List(Element(message)) {
  case destination {
    None -> []
    Some(Destination(label:, press:)) -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("peer-open"),
          event.on_click(press),
        ],
        [html.text("Open " <> label)],
      ),
    ]
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
  session: String,
) -> List(#(String, Element(message))) {
  list.map(items, fn(item) {
    let key = case item {
      turns.Narrated(block:, ..) -> block.key
      turns.Step(key:, ..) -> key
    }
    #(key, item_element(item, draw, session))
  })
}

fn item_element(
  item: turns.Item,
  draw: fn(Line) -> Element(message),
  session: String,
) -> Element(message) {
  case item {
    turns.Narrated(block:, thoughts:) ->
      block_element(block, thoughts, draw, session)
    turns.Step(key:, standing:, summary:, detail:, full:, images:) ->
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
        ..list.append(
          expander(detail, full, draw),
          pictures(session, transcript_image.ref(key), images),
        )
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
  session: String,
) -> Element(message) {
  let rows =
    list.flat_map(block.rows, fn(row) {
      case dict.get(thoughts, row.0) {
        Ok(full) -> expander([row.1], full, draw)
        Error(Nil) -> [line_row(row.1, draw)]
      }
    })
  html.div(
    [attribute.class("block")],
    list.append(
      rows,
      pictures(
        session,
        transcript_image.ref(block.key),
        transcript_image.of_block(block),
      ),
    ),
  )
}

// The pictures of a row's images, or nothing: a strip of thumbnails after the
// row's text. An image the page does not draw (a type outside the raster
// four) keeps its position, so the pictures that are drawn are named by the
// place their image holds in the row and not by how many came before. With no
// session there is no address to draw, and none is.
fn pictures(
  session: String,
  ref: String,
  images: List(Image),
) -> List(Element(message)) {
  let drawn =
    images
    |> list.index_map(fn(picture, position) { #(picture, position) })
    |> list.filter(fn(entry) { image.drawn(entry.0) })
  case session, drawn {
    "", _ | _, [] -> []
    _, _ -> [
      html.div(
        [attribute.class("pictures")],
        list.map(drawn, fn(entry) { thumbnail(session, ref, entry.1) }),
      ),
    ]
  }
}

// One picture: a thumbnail that is also the control that opens it. A
// `<details>` is opened and closed by the browser, with no script and no
// event the page hears, so the observer's page, which admits almost none,
// can grow a picture on a click. The stylesheet draws the closed form small
// and the open form at the width of the lane. The alternative text is fixed,
// since the row's own text already says the type and nothing the session
// wrote is a fit for an attribute.
fn thumbnail(session: String, ref: String, position: Int) -> Element(message) {
  html.details([attribute.class("picture")], [
    html.summary([attribute.class("picture-summary")], [
      html.img([
        attribute.class("picture-image"),
        attribute.src(image.address(session, ref, position)),
        attribute.alt("Attached image"),
        attribute.loading("lazy"),
      ]),
    ]),
  ])
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

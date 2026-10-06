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
////
//// ## Flow
////
//// `view` → `rows` → `piece_element` → `item_element` → `block_element`
//// → `line_element`
////
//// 1. `view` draws the lane, and `rows` keys one timeline row per piece, with
////    `live_entry` last while the provider is writing.
//// 2. `piece_element` draws one piece: a prompt, a fold of work, a card, an
////    answer.
//// 3. `item_element` draws one item of a fold, a step, a memory row or a
////    block of lines, and `work_items` keys them.
//// 4. `block_element` draws a block's rows; a reasoning row of any speaker
////    goes through `reasoning_row`, so every settled reasoning block closes
////    to the same heading and preview.
//// 5. `line_element` draws one transcript line inside its own memo, as
////    Markdown or as it is (`body_of`).

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
import session_view/composer
import session_view/decisions
import session_view/markdown
import session_view/step_words
import session_view/transcript_image.{type Image}
import session_view/transcript_line.{type Line}
import session_view/transcript_lines
import session_view/turns
import web_view/image
import web_view/markdown_view
import web_view/view/diff
import web_view/view/fold_row
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
/// // lane.view(component.pieces(model), component.live(model), component.top(model), OlderRequested, lane.NoReplies, component.marks(model), lane.Folds(FoldToggled), component.session_id(model))
/// ```
pub fn view(
  pieces: List(turns.Piece),
  live: List(live.Row),
  top: Top,
  load: message,
  replies: Replies(message),
  marks: Marks,
  folds: Folds(message),
  session: String,
) -> Element(message) {
  rows(
    pieces,
    live,
    boundary(top, load),
    line_element,
    replies,
    marks,
    folds,
    session,
  )
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
    /// The page's number for that strand, assigned in the order the page first
    /// showed strands and never reused, so two strands never share one.
    key: Int,
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
  Marks(active: "main", hue: turns.Primary, positions: dict.new(), key: 1)
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

/// Whether a settled turn's divider opens its work, and what pressing it sends.
///
/// The work of a settled turn is not drawn until the reader opens it: the
/// divider is a button whose press asks the page to draw the steps, and the
/// page draws them from the records it holds. The message carries the fold's
/// number (`turns.Work.id`) and nothing from the browser, so both pages draw
/// the button and an observer's socket admits its click at one path
/// (`component.fold_click`, protocol-change/070).
pub type Folds(message) {
  /// The dividers carry no handler: pressing one does nothing. A lane drawn
  /// for a test that does not open folds has no message to send.
  NoFolds

  /// Each divider that names a fold sends this message, given the fold's
  /// number.
  Folds(toggle: fn(Int) -> message)
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

/// The suffix of the attribute that marks a divider (`data-loom-fold`), so
/// `<loom-follow>` can tell a press of it from any other click in the lane and
/// take the growth that follows as the reader's own. Its value is empty and
/// fixed here; nothing from the session is in it.
pub const fold_marker = "loom-fold"

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
/// // lane.rows(pieces, [], element.none(), fn(line) { html.text(line.text) }, lane.NoReplies, lane.no_marks(), lane.NoFolds, "")
/// ```
@internal
pub fn rows(
  pieces: List(turns.Piece),
  live: List(live.Row),
  top: Element(message),
  draw: fn(Line) -> Element(message),
  replies: Replies(message),
  marks: Marks,
  folds: Folds(message),
  session: String,
) -> Element(message) {
  let newest = newest_thought(pieces)
  element.element(
    "loom-follow",
    [
      attribute.class("follow"),
      attribute.data(strand_key_marker, int.to_string(marks.key)),
    ],
    [
      top,
      keyed.div(
        [attribute.class("transcript lane"), attribute.role("log")],
        list.append(
          list.filter_map(pieces, fn(piece) {
            case piece {
              // The advisor's reviews are the panel's, never a row of the lane.
              turns.Commentary(..) -> Error(Nil)
              _ ->
                Ok(#(
                  piece_key(piece),
                  timeline_row(
                    piece,
                    draw,
                    replies,
                    marks,
                    folds,
                    session,
                    newest,
                  ),
                ))
            }
          }),
          live_entry(live, draw, marks),
        ),
      ),
    ],
  )
}

// The row key of the newest settled reasoning row in the lane, or nothing
// when it holds none. Only that row may take an open live row's state when
// the live block settles into it (`fold_row.Handoff`): a row that is older,
// such as one Load older brings in, never is the block the live row became.
// The key is the engine's identity for the row and is only compared here,
// never drawn.
fn newest_thought(pieces: List(turns.Piece)) -> String {
  pieces
  |> list.flat_map(fn(piece) {
    case piece {
      turns.Plain(block:, ..) -> thought_keys(block)
      turns.Work(items:, ..) ->
        list.flat_map(items, fn(item) {
          case item {
            turns.Narrated(block:, ..) -> thought_keys(block)
            turns.Step(..) | turns.Memory(..) -> []
          }
        })
      _ -> []
    }
  })
  |> list.last
  |> result.unwrap("")
}

fn thought_keys(block: transcript_lines.Block) -> List(String) {
  list.filter_map(block.rows, fn(row) {
    case row.1.speaker {
      transcript_line.ReasoningDigest
      | transcript_line.Reasoning
      | transcript_line.SummarizedReasoning -> Ok(row.0)
      _ -> Error(Nil)
    }
  })
}

/// The suffix of the attribute `<loom-follow>` reads the strand's key from
/// (`data-strand-key`). Its value is `Marks.key`, a small number the page
/// assigned to the strand the first time it showed it, so the attribute
/// carries none of the strand's name (protocol-change/051, the addendum on the
/// strand key).
pub const strand_key_marker = "strand-key"

// The live region as the lane's last entry, or no entry while nothing is
// streaming. Its key is a word, and a piece's key is a sequence, so the two
// never collide. It is a row of the timeline like any other, in the hue of the
// strand on screen, and its dot pulses: something is being written.
fn live_entry(
  rows: List(live.Row),
  draw: fn(Line) -> Element(message),
  marks: Marks,
) -> List(#(String, Element(message))) {
  case rows {
    [] -> []
    [_, ..] -> [
      #(
        "live",
        html.div([attribute.class("tl-row"), strip.hue_class(marks.hue)], [
          html.span(
            [
              attribute.class("dot"),
              attribute.class("pulse"),
              attribute.aria_hidden(True),
            ],
            [],
          ),
          html.div([attribute.class("tl-body")], [live.view(rows, draw)]),
        ]),
      ),
    ]
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

fn piece_key(piece: turns.Piece) -> String {
  case piece {
    turns.Plain(block:, ..)
    | turns.Prompt(block:, ..)
    | turns.Commentary(block:, ..) -> block.key
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
  folds: Folds(message),
  session: String,
  newest: String,
) -> Element(message) {
  let #(hue, target) = belongs_to(piece, marks)
  html.div([attribute.class("tl-row"), strip.hue_class(hue)], [
    html.span(
      [attribute.class("dot"), attribute.aria_hidden(True), ..marker(target)],
      [],
    ),
    html.div([attribute.class("tl-body")], [
      piece_element(piece, draw, replies, marks, folds, session, newest),
    ]),
  ])
}

// The hue a piece's dot is drawn in and the card it focuses, if any. A piece
// of the strand on screen is that strand's; a spawn and a result are the
// child's; a nudge and the advisor's commentary are the advisor's; another
// session's message is nobody's here.
fn belongs_to(piece: turns.Piece, marks: Marks) -> #(turns.Hue, Option(Int)) {
  case piece {
    turns.Plain(..)
    | turns.Prompt(..)
    | turns.Work(..)
    | turns.Missed(..)
    | turns.Decided(..) -> #(marks.hue, None)
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
  folds: Folds(message),
  session: String,
  newest: String,
) -> Element(message) {
  case piece {
    turns.Plain(block:, thoughts:, took:) ->
      block_element(block, thoughts, took, draw, session, newest)

    // A person's message: who sent it on a line of its own, and the words in
    // a bubble beneath. The sender's name is session text, a text node. The
    // role beside it is the same fixed word for every message, because only a
    // person who may operate can send one: the records do not say in which
    // capacity the sender was attached, and a word taken from the attachments
    // open at the moment would change as people attach and leave, so the same
    // message would read differently on two pages and in two turns.
    turns.Prompt(block:, name:, ..) ->
      html.div([attribute.class("prompt")], [
        html.p([attribute.class("who")], [
          html.span([attribute.class("who-name")], [html.text(name)]),
          html.text(" · operator"),
        ]),
        block_element(block, dict.new(), None, draw, session, newest),
      ])

    // A settled turn's work is its divider, a button, and the steps only
    // while the reader has the fold open. Opening is the page's own state:
    // the press goes to the server, which draws the steps from the records it
    // holds and, to stay within the page's row limit, closes the folds the
    // reader opened before this one when they do not all fit
    // (`session_view/fold_budget`). A closed fold has no steps in the piece,
    // so a turn of two hundred calls is one line here. The words in it are
    // children the server renders and escapes: the divider's figures, and
    // the work's items, keyed as an open turn's are.
    turns.Work(worked:, folding: turns.Folded, id:, ..) ->
      html.div([attribute.class("work")], [
        divider(worked, id, folds, Closed),
      ])

    // An opened fold keeps its divider, which closes it, and shows the
    // newest steps that fit the page. The earlier ones that did not are
    // counted in a line of their own, in words, so the reader knows the
    // fold is not the whole of what the turn did.
    turns.Work(worked:, items:, folding: turns.Unfolded(hidden:), id:, ..) ->
      html.div([attribute.class("work")], [
        divider(worked, id, folds, Opened),
        keyed.div(
          [attribute.class("work-items")],
          list.append(
            hidden_line(hidden),
            work_items(items, draw, session, newest),
          ),
        ),
      ])

    // A fold the reader has opened whose steps the page is still reading: the
    // divider, open, and one line that says so. The steps arrive in the next
    // render, and the divider stays where it was.
    turns.Work(worked:, folding: turns.Reading, id:, ..) ->
      html.div([attribute.class("work")], [
        divider(worked, id, folds, Opened),
        keyed.div([attribute.class("work-items")], [
          #(
            "reading",
            html.p([attribute.class("work-hidden")], [
              html.text("Reading the steps…"),
            ]),
          ),
        ]),
      ])

    // The turn still running is drawn open, with no divider to fold it.
    turns.Work(items:, folding: turns.Open, ..) ->
      keyed.div(
        [attribute.class("work open")],
        work_items(items, draw, session, newest),
      )

    // A spawn is a line of the strand that made it: the verb the step words
    // use, the child's tag, and the purpose it was given. The tag is the
    // name the child's card carries (`agent_roster.short_name`), so one
    // strand has one name on the page. The purpose is the
    // model's text, a text node.
    turns.Spawned(child:, purpose:, hue:, standing:, ..) ->
      html.p(
        [attribute.class("who"), attribute.class("spawn"), strip.hue_class(hue)],
        [
          html.text("Spawned"),
          ..list.append(
            case child {
              Some(child) -> [
                html.text(" "),
                tag(agent_roster.short_name(child), position(marks, child)),
              ]
              None -> [html.text(" · " <> standing_text(standing))]
            },
            case purpose {
              "" -> []
              _ -> [
                html.span([attribute.class("spawn-purpose")], [
                  html.text(" · " <> purpose),
                ]),
              ]
            },
          )
        ],
      )

    // A child's result is a line naming it, and the report beneath it as
    // the first line the reader scans, opened to the whole report from that
    // line. A report of one short line has nothing to open.
    turns.Returned(child:, outcome:, report:, hue:, ..) ->
      html.div([attribute.class("result"), strip.hue_class(hue)], [
        html.p([attribute.class("who")], [
          tag(agent_roster.short_name(child), position(marks, child)),
          html.text(" " <> step_words.returned(outcome)),
        ]),
        result_report(report),
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
          html.text(decisions.verb(decision.verdict)),
          html.span([attribute.class("decided-tool")], [
            html.text(decisions.tool_words(decision.tool)),
          ]),
        ],
      )

    // The advisor's own commentary draws no row. The panel's commentary
    // section is the record of every review (`view/commentary`), and the
    // advisor's dot on a nudge card is the way into its transcript, so a row
    // here would cost a timeline slot and say nothing the reader lacks.
    // `rows` filters these pieces out before a timeline row exists, so this
    // arm is the closed case's other half and is never drawn.
    turns.Commentary(..) -> element.none()
  }
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
  parsed_card_body(body)
}

// A report keeps its preview and body in one leaf memo. Drawing the body
// directly there avoids nesting another memo whose entry Lustre would drop
// when the enclosing report's dependencies are unchanged.
fn parsed_card_body(body: String) -> Element(message) {
  html.div(
    [attribute.class("card-body"), attribute.class("markdown")],
    markdown_view.blocks(markdown.parse(body)),
  )
}

// Whether a fold's work is shown.
type Shown {
  Closed
  Opened
}

// The divider of a settled turn's work: a button when the fold has a number to
// be opened by, and plain words when it has none. Its marker, a fixed word,
// is how `<loom-follow>` tells the press from any other click in the lane, so
// the growth that follows is the reader's own and does not scroll the page past
// the divider they pressed. The glyph is drawn by the stylesheet from the
// button's state, so the button holds one text node and every click lands on
// the button itself.
fn divider(
  worked: turns.Worked,
  id: Option(Int),
  folds: Folds(message),
  shown: Shown,
) -> Element(message) {
  let words = html.text(turns.divider(worked))
  case id, folds {
    Some(id), Folds(toggle:) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("work-toggle"),
          attribute.aria_expanded(shown == Opened),
          attribute.data(fold_marker, "fold"),
          event.on_click(toggle(id)),
        ],
        [words],
      )
    Some(_), NoFolds | None, Folds(_) | None, NoFolds ->
      html.span([attribute.class("work-toggle")], [words])
  }
}

// The line that says how many earlier steps of an opened fold are not
// drawn, or nothing when every step is.
fn hidden_line(hidden: Int) -> List(#(String, Element(message))) {
  case hidden {
    0 -> []
    _ -> [
      #(
        "hidden",
        html.p([attribute.class("work-hidden")], [
          html.text(
            int.to_string(hidden)
            <> " earlier steps are not shown, to keep the page small.",
          ),
        ]),
      ),
    ]
  }
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
  newest: String,
) -> List(#(String, Element(message))) {
  list.map(items, fn(item) {
    let key = case item {
      turns.Narrated(block:, ..) -> block.key
      turns.Step(key:, ..) | turns.Memory(key:, ..) -> key
    }
    #(key, item_element(item, draw, session, newest))
  })
}

// One item of the fold, each a line with the rest behind it. A call's body is
// its whole program and result when the page holds them, and the rows the
// transcript draws under the call when it does not; the two say the same
// thing, so only one is drawn.
fn item_element(
  item: turns.Item,
  draw: fn(Line) -> Element(message),
  session: String,
  newest: String,
) -> Element(message) {
  case item {
    turns.Narrated(block:, thoughts:, took:) ->
      block_element(block, thoughts, took, draw, session, newest)
    turns.Memory(lines:, full:, ..) ->
      fold_row.memory(
        step_words.memory(lines),
        list.map(full, fold_row.line_row(_, draw)),
      )
    turns.Step(key:, standing:, words:, detail:, full:, images:) -> {
      let rows = case full {
        [] -> detail
        [_, ..] -> full
      }
      fold_row.step(
        standing,
        words,
        list.append(
          fold_row.step_body(standing, words, rows, draw),
          pictures(session, transcript_image.ref(key), images),
        ),
      )
    }
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
// never reaches the lane. A reasoning row is a row of its own (`reasoning_row`;
// the time is the response's, from the record before it to its own, not the
// block's alone), opened to the full reasoning when the page holds it
// (`thoughts`, by the row's key).
fn block_element(
  block: transcript_lines.Block,
  thoughts: Dict(String, List(Line)),
  took: Option(Int),
  draw: fn(Line) -> Element(message),
  session: String,
  newest: String,
) -> Element(message) {
  let rows =
    list.map(block.rows, fn(row) {
      let heir = case row.0 == newest {
        True -> fold_row.Takes
        False -> fold_row.Declines
      }
      case row.1.speaker {
        transcript_line.ReasoningDigest -> {
          let held = result.unwrap(dict.get(thoughts, row.0), [])
          case held {
            [first, ..] ->
              reasoning_row(step_words.Raw, first.text, held, took, heir, draw)
            [] ->
              reasoning_row(step_words.Raw, row.1.text, [], took, heir, draw)
          }
        }
        transcript_line.Reasoning ->
          reasoning_row(
            step_words.Raw,
            row.1.text,
            more_of(row.1.text),
            took,
            heir,
            draw,
          )
        transcript_line.SummarizedReasoning ->
          summary_row(row.1.text, took, heir, draw)
        _ -> fold_row.line_row(row.1, draw)
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

// Every settled reasoning block is drawn by this one function, whichever
// speaker its row has: the digest the transcript keeps for a block (with the
// whole text beside it when the page holds it), the whole text itself, or a
// provider's summary. The row is the terminal's heading (`step_words`: the
// verb, the line count when there is more to open, the time), then a one-line
// Markdown preview of the text's first line, and behind the chevron the whole
// text as Markdown. `body` is what opens: empty when the preview already says
// everything, in which case the row has no chevron and no count. The text is
// the model's or the provider's and is drawn only as text nodes.
fn reasoning_row(
  provenance: step_words.Provenance,
  text: String,
  body: List(Line),
  took: Option(Int),
  heir: fold_row.Handoff,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  let count = case body {
    [] -> None
    [_, ..] -> Some(list.length(string.split(text, "\n")))
  }
  fold_row.reasoning(
    step_words.reasoning_of(provenance, count, took),
    preview(text),
    list.map(body, fold_row.line_row(_, draw)),
    heir,
  )
}

// The one-line preview of a settled block, parsed once. A settled block's text
// does not change, so the memo's one dependency is the text and a lane render
// that finds it unchanged does no Markdown work for it. Only the preview is
// memoized: the body's own line memos are leaves, and a memo around them
// would drop their cache entries when it hit (see `rows`).
fn preview(text: String) -> List(Element(message)) {
  case string.trim(text) {
    "" -> []
    _ -> [
      element.memo([element.ref(text)], fn() {
        fold_row.preview_span(markdown_view.line(text, step_words.result_limit))
      }),
    ]
  }
}

// A summarized block's row text is the terminal's header line and the summary
// beneath it; the summary is the text, and the header's words are the
// heading's.
fn summary_row(
  text: String,
  took: Option(Int),
  heir: fold_row.Handoff,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  let summary = case string.split_once(text, "\n") {
    Ok(#(_, summary)) -> summary
    Error(Nil) -> text
  }
  reasoning_row(
    step_words.Summarized,
    summary,
    more_of(summary),
    took,
    heir,
    draw,
  )
}

// The body of a block whose whole text is the row's text: the text itself
// when it runs past the one line the preview shows, and nothing when it does
// not, so a short block is not opened to what it already says.
fn more_of(text: String) -> List(Line) {
  let trimmed = string.trim(text)
  case
    string.contains(trimmed, "\n")
    || string.length(trimmed) > step_words.result_limit
  {
    True -> [transcript_line.Line(transcript_line.Reasoning, text)]
    False -> []
  }
}

// A child's report under its who-line: nothing for an empty report, the text
// alone for one short line, and otherwise the report's first line as the row
// a reader scans, with the whole report in Markdown behind it. The line is the
// report's own Markdown cut to one row, so its bold and code draw as they do
// in the body, and a report whose breaks arrived as the characters `\n` is
// read with real ones first (`step_words.spoken_breaks`), so no backslash is
// drawn and the second line is behind the chevron.
// Settled reports are unchanged while provider fragments arrive. Their
// preview and body must both be built inside the memo, so those fragments
// do not parse the report before Lustre can reuse it.
fn result_report(report: String) -> Element(message) {
  use <- element.memo([element.ref(report)])
  let report = step_words.spoken_breaks(report)
  let line = markdown_view.line(report, step_words.result_limit)
  let trimmed = string.trim(report)
  let longer =
    string.contains(trimmed, "\n")
    || string.length(trimmed) > step_words.result_limit
  element.fragment(case trimmed, longer {
    "", _ -> []
    _, False -> [html.p([attribute.class("result-line")], line)]
    _, True -> [fold_row.reading(line, [parsed_card_body(report)])]
  })
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

// A line is the shared projection's, which words a collapsed row with the
// terminal's `Ctrl+G` hint. The page has no such key, so the hint is taken off
// the row here, at the one place the page draws a line, and the rows the
// reader opens are the chevron's.
fn line_element(shown: Line) -> Element(message) {
  let line =
    transcript_line.Line(
      ..shown,
      text: composer.without_expand_hint(shown.text),
    )

  case body_of(line.speaker) {
    // A patch is a diff, drawn in colour a line at a time by `view/diff`.
    Literal if line.speaker == transcript_line.ToolPatch ->
      diff.of_text(line.text)

    // A failed response's cause is labelled, so it reads as a status of the
    // turn and not as the assistant's words. The label is fixed text and the
    // cause is the engine's, each a text node.
    Literal if line.speaker == transcript_line.Failure ->
      html.pre([attribute.class("line"), speaker_class(line.speaker)], [
        html.span([attribute.class("failure-label")], [html.text("Failed:")]),
        html.text(" " <> line.text),
      ])
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
    | transcript_line.ToolGroup
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

    // A message between agents is its heading and its body in one text; the
    // terminal draws the heading as a heading, and here it is kept a line of
    // its own rather than run into the body as one Markdown paragraph.
    transcript_line.SentMessage
    | transcript_line.StrandMessage
    | transcript_line.PeerMessage -> Literal

    // A program block's text is its title, its foot and its body, already
    // laid out line by line.
    transcript_line.ProgramRunning
    | transcript_line.ProgramFailure
    | transcript_line.ProgramSettled
    | transcript_line.ImageRow(..) -> Literal
  }
}

// A class per speaker, which is the whole of a line's styling here as in the
// terminal. The stylesheet decides what each looks like.
fn speaker_class(
  speaker: transcript_line.Speaker,
) -> attribute.Attribute(message) {
  case speaker {
    transcript_line.System -> attribute.class("system")
    transcript_line.ToolGroup -> attribute.class("tool-group")
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
    transcript_line.SentMessage -> attribute.class("sent-message")
    transcript_line.StrandMessage -> attribute.class("strand-message")
    transcript_line.PeerMessage -> attribute.class("peer-message")
    transcript_line.ProgramRunning -> attribute.class("program-running")
    transcript_line.ProgramFailure -> attribute.class("program-failure")
    transcript_line.ProgramSettled -> attribute.class("program-settled")
    transcript_line.ImageRow(..) -> attribute.class("image-row")
  }
}

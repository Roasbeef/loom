//// "Lifted from this session": the live rail beside the transcript, and the
//// sheet that carries it on a phone.
////
//// `session_view/attention` reads the lane's pieces and the register's
//// approvals and says which rows a reader who looked away would want first.
//// This module draws that answer. It decides nothing about the session and
//// sends nothing to it: the rail is a second view of rows the transcript
//// already shows, with a way to get from each one to its place in the stream.
////
//// ## Two groups
////
//// "Needs you" holds the pinned rows, an approval that has no decision yet.
//// "Insights" holds the rest. An empty group draws nothing, and a rail with
//// no rows draws nothing at all, so a quiet session has no rail.
////
//// A pinned row never folds and never carries a handler. An approval is
//// decided in the dock, above the composer, under the rules of
//// protocol-change/051 (Deny first, arming, no autofocus), and a second
//// control here would be a second place those rules had to hold. The row says
//// where the card is ("Decide in the dock ↓") and its press scrolls the dock
//// into view in the browser (`web_client/follow`). On an observer's page
//// there is no dock and no deciding, so the row says that the operator
//// decides, and carries no jump.
////
//// An insight is drawn whole until the reader opens it once, and folded to
//// one line for the rest of the page's life afterwards. The opened keys are
//// the server model's (`component.RailOpened`); nothing is stored in the
//// browser and nothing records what the reader has seen. The press that opens
//// an insight is the one handler this module draws, and it asks the server
//// to remember a key the server drew into the handler.
////
//// ## Jumps
////
//// Every row's button carries `data-loom-jump`, whose value names the
//// transcript row to scroll to, or `dock`. The value is a daemon identity
//// (`target`), never session text, and the press is handled in the browser
//// alone (`web_client/jump_rule`). A lifted row's `head` is session text: it
//// is a text node and nothing else, and no attribute, class or key is built
//// from it.
////
//// ## The phone sheet
////
//// Below 980px the strip is a row of cards, and there is no room for a rail
//// in it. The stylesheet hides the rail there, and `sheet` draws a bar above
//// the dock, "N need you · M insights ▴", that opens the same rows as a
//// sheet over the transcript. It is a native `<details>`, so opening it costs
//// the server nothing, and the sheet's rows carry no handler: it shows
//// insights as the page's opened set says, and a jump closes it
//// (`web_client/follow`).

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/attention.{type Lifted}
import session_view/turns

/// The marker attribute a press is routed by: its value names the row to
/// scroll to. It is read by `web_client/jump_rule`, which owns the same name.
pub const jump_attribute = "data-loom-jump"

/// The marker value that names the dock instead of a transcript row.
pub const dock_target = "dock"

/// Whether the page has a dock where an approval is decided.
pub type Dock {
  /// An operator's page: the approval card is in the dock above the composer.
  InDock

  /// An observer's page: there is no dock, and nobody here decides.
  NoDock
}

/// One lifted row with the place its press goes.
pub type Item {
  Item(
    /// The row the attention reading lifted.
    lifted: Lifted,
    /// The value of the row's `data-loom-jump`: a transcript row's key, or
    /// `dock_target`. Empty when the row has nowhere to go.
    target: String,
  )
}

/// What a rail needs to be drawn.
pub type Rail(message) {
  Rail(
    /// The rows, in the order `attention.lift` gave them.
    items: List(Item),
    /// The keys of the insights the reader has opened.
    opened: List(String),
    /// The strand on screen, named on a row that belongs to it.
    strand: String,
    /// Whether an approval is decided on this page.
    dock: Dock,
    /// The message a press on an unopened insight sends, given its key. It
    /// is `None` for the sheet, whose rows are not handlers.
    open: Option(fn(String) -> message),
  )
}

/// The rows of the page's lane with the place each press goes: an approval
/// goes to the dock, and any other row to the transcript row that holds it.
///
/// A step inside a turn's fold is lifted as `<work key>#<index>`, and a failed
/// response inside a fold by its block's key, but only the turn's row is in
/// the lane, so both resolve to the turn's key. A key that names no piece
/// stays as it is, and the browser finds no row for it and does nothing.
///
/// ## Examples
///
/// ```gleam
/// assert lifted.items([], [], lifted.InDock) == []
/// ```
pub fn items(
  pieces: List(turns.Piece),
  lifted: List(Lifted),
  dock: Dock,
) -> List(Item) {
  list.map(lifted, fn(row) {
    Item(lifted: row, target: target(pieces, row, dock))
  })
}

/// Where one row's press goes: the dock for an approval on a page that has
/// one, nowhere for an approval on a page that has not, and the lane's row
/// that holds the lifted key for everything else.
fn target(pieces: List(turns.Piece), row: Lifted, dock: Dock) -> String {
  // Every kind of row is named, so a new kind has to say where it goes.
  case row.kind, dock {
    attention.ApprovalPending(..), InDock -> dock_target
    attention.ApprovalPending(..), NoDock -> ""
    attention.FailedStep, _
    | attention.FailedTurn, _
    | attention.SubagentResult(..), _
    | attention.PeerMessage(..), _
    -> row_of(pieces, row.key)
  }
}

/// The key of the lane row that holds a lifted key: the key itself when it is
/// a piece's, the turn before the `#` for a step in a fold, and the turn whose
/// fold holds the block otherwise.
fn row_of(pieces: List(turns.Piece), key: String) -> String {
  let is_piece = list.any(pieces, fn(piece) { piece_key(piece) == key })

  // A piece's own key is already a row; only the others need a search.
  case is_piece {
    True -> key
    False -> fold_holding(pieces, key)
  }
}

/// The key of the turn that holds a lifted key inside its fold, or the key
/// itself when no turn does. A step is `<work key>#<index>`; a failed response
/// is a narrated block's key.
fn fold_holding(pieces: List(turns.Piece), key: String) -> String {
  // A step's key names its turn before the separator.
  case string.split_once(key, "#") {
    Ok(#(work, _)) -> work
    Error(Nil) -> work_holding(pieces, key)
  }
}

/// The key of the turn whose fold holds a narrated block with this key, or the
/// key itself when none does.
fn work_holding(pieces: List(turns.Piece), key: String) -> String {
  let holder = list.find(pieces, fn(piece) { holds_block(piece, key) })

  // A key no fold holds stays as it is, and the browser finds no row for it.
  case holder {
    Ok(piece) -> piece_key(piece)
    Error(Nil) -> key
  }
}

/// Whether a piece is a turn whose fold has a narrated block with this key.
fn holds_block(piece: turns.Piece, key: String) -> Bool {
  // Only a turn's work has a fold to hold a block.
  case piece {
    turns.Work(items:, ..) -> list.any(items, fn(item) { narrates(item, key) })
    turns.Plain(..)
    | turns.Prompt(..)
    | turns.Spawned(..)
    | turns.Returned(..)
    | turns.Nudged(..)
    | turns.Commentary(..)
    | turns.Peer(..)
    | turns.Sibling(..)
    | turns.Trigger(..)
    | turns.Missed(..)
    | turns.Decided(..) -> False
  }
}

/// Whether a fold's item is a narrated block with this key.
fn narrates(item: turns.Item, key: String) -> Bool {
  // Steps and memory rows carry no block of their own.
  case item {
    turns.Narrated(block:, ..) -> block.key == key
    turns.Step(..) | turns.Memory(..) -> False
  }
}

/// The key the lane draws a piece's row under, which is the value of the row's
/// `data-loom-row` marker.
///
/// ## Examples
///
/// ```gleam
/// // lifted.piece_key(piece)
/// ```
pub fn piece_key(piece: turns.Piece) -> String {
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
    | turns.Trigger(key:, ..)
    | turns.Missed(key:, ..)
    | turns.Decided(key:, ..) -> key
  }
}

/// The rail for the Strands pane, or nothing when no row was lifted.
///
/// ## Examples
///
/// ```gleam
/// // lifted.view(lifted.Rail([], [], "main", lifted.InDock, None))
/// ```
pub fn view(rail: Rail(message)) -> Element(message) {
  case rail.items {
    [] -> element.none()
    items ->
      html.section(
        [
          attribute.class("lifted"),
          attribute.aria_label("Lifted from this session"),
        ],
        [
          html.h2([attribute.class("panel-title")], [
            html.text("Lifted from this session"),
          ]),
          groups(rail, items),
        ],
      )
  }
}

/// The bar above the dock and the sheet it opens, for a phone, or nothing when
/// no row was lifted. The stylesheet draws it only below 980px.
///
/// ## Examples
///
/// ```gleam
/// // lifted.sheet(lifted.Rail([], [], "main", lifted.InDock, None))
/// ```
pub fn sheet(rail: Rail(message)) -> Element(message) {
  case rail.items {
    [] -> element.none()
    items ->
      html.details(
        [attribute.class("lift-sheet"), attribute.data("loom-sheet", "lifted")],
        [
          html.summary([attribute.class("lift-bar")], [
            html.text(bar_words(items)),
          ]),
          html.div([attribute.class("lift-sheet-body")], [
            groups(Rail(..rail, open: None), items),
          ]),
        ],
      )
  }
}

/// The words on the sheet's bar: how many rows need the owner and how many
/// are insights, each part left out when it is zero, and an arrow that says the
/// bar opens upward.
///
/// ## Examples
///
/// ```gleam
/// assert lifted.count_words(2, 1) == "2 need you · 1 insight"
/// assert lifted.count_words(0, 3) == "3 insights"
/// ```
pub fn count_words(needing: Int, insights: Int) -> String {
  let need = plural(needing, "1 needs you", " need you")
  let known = plural(insights, "1 insight", " insights")

  string.join(list.append(need, known), " · ")
}

/// A count's words, or none for zero: the whole phrase for one, and the
/// number joined to the plural phrase for any other count.
fn plural(count: Int, one: String, many: String) -> List(String) {
  // A zero part is left out of the bar rather than said.
  case count {
    0 -> []
    1 -> [one]
    n -> [int.to_string(n) <> many]
  }
}

/// The sheet bar's words for the rows, with the arrow that says it opens up.
fn bar_words(items: List(Item)) -> String {
  let #(pinned, rest) = split(items)

  count_words(list.length(pinned), list.length(rest)) <> " ▴"
}

/// The rows that need the owner, and the rest, each in their given order.
fn split(items: List(Item)) -> #(List(Item), List(Item)) {
  list.partition(items, fn(item) {
    item.lifted.hold == attention.PinnedUntilAnswered
  })
}

/// The two groups, each drawn only when it holds a row.
fn groups(rail: Rail(message), items: List(Item)) -> Element(message) {
  let #(pinned, rest) = split(items)

  html.div([attribute.class("lift-groups")], [
    group("Needs you", "lift-needs", pinned, rail),
    group("Insights", "lift-insights", rest, rail),
  ])
}

/// One titled group of rows, or nothing when it has none.
fn group(
  title: String,
  class: String,
  items: List(Item),
  rail: Rail(message),
) -> Element(message) {
  // An empty group leaves no heading over nothing.
  case items {
    [] -> element.none()
    items ->
      html.section([attribute.class("lift-group"), attribute.class(class)], [
        html.h3([attribute.class("lift-group-title")], [html.text(title)]),
        html.ul([attribute.class("lift-list")], list.map(items, row(_, rail))),
      ])
  }
}

/// One row: a button that jumps, and for an unopened insight that has a
/// handler, also asks the server to remember that it was opened.
fn row(item: Item, rail: Rail(message)) -> Element(message) {
  let lifted = item.lifted
  let folded = list.contains(rail.opened, lifted.key)

  html.li([attribute.class("lift"), attribute.class(state(lifted, folded))], [
    html.button(
      list.flatten([
        [attribute.type_("button"), attribute.class("lift-press")],
        jump(item.target),
        press(lifted, folded, rail.open),
        expanded(lifted, folded),
      ]),
      [
        html.span([attribute.class("lift-kind")], [html.text(kind_word(lifted))]),
        html.span([attribute.class("lift-source")], [
          html.text(source_words(lifted, rail.strand)),
        ]),
        html.span([attribute.class("lift-head")], [html.text(lifted.head)]),
        decide(lifted, rail.dock),
      ],
    ),
  ])
}

/// The class that says how a row is drawn: pinned, whole, or folded to a line.
fn state(row: Lifted, folded: Bool) -> String {
  // A pinned row never folds, whatever the opened set holds.
  case row.hold, folded {
    attention.PinnedUntilAnswered, _ -> "lift-pinned"
    attention.FoldsOnceOpened, True -> "lift-folded"
    attention.FoldsOnceOpened, False -> "lift-open"
  }
}

/// The jump marker for a target, or none when the row has nowhere to go.
fn jump(target: String) -> List(attribute.Attribute(message)) {
  // An empty target is an approval on a page with no dock.
  case target {
    "" -> []
    target -> [attribute.attribute(jump_attribute, target)]
  }
}

/// The handler that records an open: only an unopened insight on a rail that
/// has one. A pinned row and a folded insight draw none.
fn press(
  row: Lifted,
  folded: Bool,
  open: Option(fn(String) -> message),
) -> List(attribute.Attribute(message)) {
  // The press names the key the view drew, not anything the browser sends.
  case row.hold, folded, open {
    attention.FoldsOnceOpened, False, Some(open) -> [
      event.on_click(open(row.key)),
    ]
    attention.FoldsOnceOpened, True, _
    | attention.FoldsOnceOpened, False, None
    | attention.PinnedUntilAnswered, _, _
    -> []
  }
}

/// `aria-expanded` for an insight, which is the only kind of row that folds.
fn expanded(row: Lifted, folded: Bool) -> List(attribute.Attribute(message)) {
  // A pinned row is always whole, so it states no expansion.
  case row.hold, folded {
    attention.PinnedUntilAnswered, _ -> []
    attention.FoldsOnceOpened, True -> [
      attribute.attribute("aria-expanded", "false"),
    ]
    attention.FoldsOnceOpened, False -> [
      attribute.attribute("aria-expanded", "true"),
    ]
  }
}

/// The line that says where an approval is decided, or nothing for any other
/// row.
fn decide(row: Lifted, dock: Dock) -> Element(message) {
  // An observer's page has no dock, and says who decides instead.
  case row.kind, dock {
    attention.ApprovalPending(..), InDock ->
      html.span([attribute.class("lift-go")], [
        html.text("Decide in the dock ↓"),
      ])
    attention.ApprovalPending(..), NoDock ->
      html.span([attribute.class("lift-go")], [
        html.text("The operator decides"),
      ])
    attention.FailedStep, _
    | attention.FailedTurn, _
    | attention.SubagentResult(..), _
    | attention.PeerMessage(..), _
    -> element.none()
  }
}

/// The word a row's kind is named by.
///
/// ## Examples
///
/// ```gleam
/// assert lifted.kind_word(row) == "Approval"
/// ```
pub fn kind_word(row: Lifted) -> String {
  case row.kind {
    attention.ApprovalPending(..) -> "Approval"
    attention.FailedStep -> "Failed step"
    attention.FailedTurn -> "Failed"
    attention.SubagentResult(..) -> "Result"
    attention.PeerMessage(..) -> "Peer"
  }
}

/// Where a row came from: the tool an approval asks to use, the child or the
/// session that spoke, or the strand on screen for a failure in it. Every part
/// is text the session or its peers named, so it is drawn as text only.
fn source_words(row: Lifted, strand: String) -> String {
  case row.kind {
    attention.ApprovalPending(tool:) -> tool
    attention.SubagentResult(child:) -> child
    attention.PeerMessage(session:, strand: peer_strand) ->
      session <> " · " <> peer_strand
    attention.FailedStep | attention.FailedTurn -> strand
  }
}

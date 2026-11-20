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
//// "Needs you" holds the pinned rows: an approval that has no decision yet, an
//// open ask and a stuck strand. "Insights" holds the rest. Each group's title
//// carries its count and a fixed gloss (`pinned until answered`, `fold once
//// read`), and a note at the foot says how the rows are held. An empty group
//// draws nothing, and a rail with no rows draws nothing at all, so a quiet
//// session has no rail.
////
//// A row is a card: a chip with the kind's word, the strand or tool it came
//// from, and a link to its place in the stream on the first line, then the
//// row's words. The time the row was raised comes before the strand
//// (`Item.at`), a `<loom-time>` (`view/stamp`) so the browser words it in its
//// own zone. A row's time is its record's: the entry time of a lane row, an
//// approval's `raised_at`, an ask's or find's `created_at`, a stuck strand's
//// `failed_at`. A row whose record carries none says the strand alone.
////
//// A pinned row never folds, and its own button carries no handler. An approval is
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
//// an insight is the first handler this module draws, and it asks the server
//// to remember a key the server drew into the handler.
////
//// ## Actions
////
//// A page that may act on the session's records draws buttons under a card's
//// own button, as the card's last child (protocol-change/051, the addendum on
//// the live rail's actions). A stuck strand's card offers "Retry the last
//// step", and a find's card offers "File issue" and "Dismiss". The buttons are
//// not inside the card's button, since a button cannot hold a button, and the
//// card's button and the ask's form keep the child positions the socket
//// admits presses at. What a button sends is the page's choice (`Offer`): this
//// module draws the offer it is handed and decides nothing, so a page that may
//// not act is handed `NoOffer` for every row and draws no button at all.
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
//// the dock, "N need you · M insights" with "Lifted ▴" at its right, that
//// opens the same rows as a sheet that rises from the bar over the transcript. It is a native `<details>`, so opening it costs
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
import web_view/view/stamp

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
    /// When the row was raised, in Unix milliseconds, drawn before the source
    /// in the card's header (`13:40`). `None` for a row whose record carries
    /// no time, and the header then draws the source alone.
    at: Option(Int),
  )
}

/// What a page lifted: the rows and whether it has a dock. It is worked out
/// once per render (`component.lift`) and handed to every place that draws it.
pub type Lift {
  Lift(
    /// The rows with the place each press goes.
    items: List(Item),
    /// Whether an approval is decided on this page.
    dock: Dock,
  )
}

/// What a card offers beneath its own button. The page decides it from what the
/// page may do and what it has read, and the view draws exactly that.
pub type Offer(message) {
  /// Nothing: the row has no action, or the page may not act on it, or the
  /// page has not read what the action needs.
  NoOffer

  /// A stuck strand's "Retry the last step". The message names the strand.
  RetryOffer(press: message)

  /// A find's two ways to close it: "File issue" and "Dismiss".
  CloseOffer(file: message, dismiss: message)

  /// An action is with the daemon. The card says so and offers nothing else,
  /// so a second press cannot be made.
  OfferSent
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
    /// The catalogue's name for a listed session, given its identity, or
    /// `None` for one the page does not list.
    names: fn(String) -> Option(String),
    /// The message a press on an unopened insight sends, given its key. It
    /// is `None` for the sheet, whose rows are not handlers.
    open: Option(fn(String) -> message),
    /// What the page draws under a row, given its key: an open ask's form on a
    /// page that may answer, and nothing for every other row. The sheet draws
    /// the same, so the phone answers as the rail does.
    under: fn(String) -> Element(message),
    /// What the page offers beneath a row. The sheet draws the same offers, so
    /// the phone acts as the rail does.
    offer: fn(Lifted) -> Offer(message),
    /// The page's word on the last answer, or empty. It is drawn after the
    /// groups, so no path of the rail moves, and it keeps the rail on screen
    /// after the last row it describes has left.
    status: String,
  )
}

/// The rows of the page's lane with the place each press goes: an approval
/// goes to the dock, and any other row to the transcript row that holds it.
///
/// A turn's failed steps are lifted under the turn's own key, and a failed
/// response inside a fold by its block's key, but only the turn's row is in
/// the lane, so the block resolves to the turn's key. A key that names no
/// piece stays as it is, and the browser finds no row for it and does nothing.
///
/// ## Examples
///
/// ```gleam
/// assert lifted.items([], [], lifted.InDock, fn(_) { None }) == []
/// ```
pub fn items(
  pieces: List(turns.Piece),
  lifted: List(Lifted),
  dock: Dock,
  at: fn(String) -> Option(Int),
) -> List(Item) {
  list.map(lifted, fn(row) {
    Item(lifted: row, target: target(pieces, row, dock), at: at(row.key))
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

    // A record of the session's own is not a row of the lane, so a press has
    // nowhere to jump.
    attention.AskPending, _
    | attention.StuckStrand(..), _
    | attention.FindOpen(..), _
    -> ""
  }
}

/// The key of the lane row that holds a lifted key: the key itself when it is
/// a piece's, and otherwise the turn whose fold holds a narrated block with
/// that key (a failed response inside a fold).
fn row_of(pieces: List(turns.Piece), key: String) -> String {
  let is_piece = list.any(pieces, fn(piece) { piece_key(piece) == key })

  // A piece's own key is already a row; only the others need a search.
  case is_piece {
    True -> key
    False -> work_holding(pieces, key)
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
  case rail.items, rail.status {
    [], "" -> element.none()
    [], status ->
      html.section(
        [
          attribute.class("lifted"),
          attribute.aria_label("Lifted from this session"),
        ],
        [
          html.h2([attribute.class("panel-title")], [
            html.text("Lifted from this session"),
          ]),
          groups(rail, []),
          answered(status),
        ],
      )
    items, status ->
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
          answered(status),
        ],
      )
  }
}

/// The page's word on the last answer, drawn after the groups so that the
/// groups keep the child positions the socket admits presses at. Nothing when
/// there is none.
fn answered(status: String) -> Element(message) {
  case status {
    "" -> element.none()
    words ->
      html.p([attribute.class("lift-status"), attribute.role("status")], [
        html.text(words),
      ])
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
          html.summary([attribute.class("lift-bar")], bar(items)),
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

/// The sheet bar's children: the count of rows that need the owner, set apart
/// so the stylesheet can colour it, the count of insights after it, and the
/// word and arrow at the right that say the bar opens upward. Each count is
/// left out when it is zero, as `count_words` leaves it. Two more children, the
/// title and "Close ▾", are the bar's face once the sheet is open.
fn bar(items: List(Item)) -> List(Element(message)) {
  let #(pinned, rest) = split(items)
  let need = plural(list.length(pinned), "1 needs you", " need you")
  let known = plural(list.length(rest), "1 insight", " insights")

  list.flatten([
    list.map(need, fn(words) {
      html.span([attribute.class("lift-bar-need")], [html.text(words)])
    }),
    list.map(known, fn(words) {
      html.span([attribute.class("lift-bar-count")], [
        html.text(case need {
          [] -> words
          [_, ..] -> "· " <> words
        }),
      ])
    }),
    [
      html.span([attribute.class("lift-bar-more")], [html.text("Lifted ▴")]),

      // The open face: while the sheet is open the bar is its header, and the
      // stylesheet swaps these two in for the counts and "Lifted ▴".
      html.span([attribute.class("lift-bar-title")], [
        html.text("Lifted from this session"),
      ]),
      html.span([attribute.class("lift-bar-close")], [html.text("Close ▾")]),
    ],
  ])
}

/// The rows that need the owner, and the rest, each in their given order.
fn split(items: List(Item)) -> #(List(Item), List(Item)) {
  list.partition(items, fn(item) {
    item.lifted.hold == attention.PinnedUntilAnswered
  })
}

/// The two groups, each drawn only when it holds a row, and the closing note
/// that says how the rows are held.
fn groups(rail: Rail(message), items: List(Item)) -> Element(message) {
  let #(pinned, rest) = split(items)

  html.div([attribute.class("lift-groups")], [
    group("Needs you", "pinned until answered", "lift-needs", pinned, rail),
    group("Insights", "fold once read", "lift-insights", rest, rail),
    note(items, rail.dock),
  ])
}

/// The note at the foot of the rail: what stays pinned and what folds. It
/// says only what the page does for every row, and on a page with an approval
/// in the rail it adds where that approval is decided. It is the groups'
/// last sibling, so no group's position moves. A rail with no rows has none.
fn note(items: List(Item), dock: Dock) -> Element(message) {
  let approving =
    list.any(items, fn(item) {
      case item.lifted.kind {
        attention.ApprovalPending(..) -> True
        attention.FailedStep
        | attention.FailedTurn
        | attention.SubagentResult(..)
        | attention.PeerMessage(..)
        | attention.AskPending
        | attention.StuckStrand(..)
        | attention.FindOpen(..) -> False
      }
    })

  // A rail with no rows has nothing to explain.
  case items {
    [] -> element.none()
    [_, ..] ->
      html.p([attribute.class("lift-note")], [
        html.text(
          "Asks, approvals and stuck strands stay pinned here until they are "
          <> "answered. Finds, failed calls and turns, sub-agent results and "
          <> "peer messages fold to one line once opened."
          <> case approving, dock {
            True, InDock ->
              " An approval is decided only from the dock on this page. The "
              <> "rail points at it and never decides."
            True, NoDock | False, _ -> ""
          },
        ),
      ])
  }
}

/// One titled group of rows, or nothing when it has none. The title carries
/// the count and a gloss on how the group's rows are held, both fixed words.
fn group(
  title: String,
  gloss: String,
  class: String,
  items: List(Item),
  rail: Rail(message),
) -> Element(message) {
  // An empty group leaves no heading over nothing.
  case items {
    [] -> element.none()
    items ->
      html.section([attribute.class("lift-group"), attribute.class(class)], [
        html.h3([attribute.class("lift-group-title")], [
          html.span([], [
            html.text(title <> " · " <> int.to_string(list.length(items))),
          ]),
          html.small([attribute.class("lift-gloss")], [html.text(gloss)]),
        ]),
        html.ul([attribute.class("lift-list")], list.map(items, row(_, rail))),
      ])
  }
}

/// One row: a card whose button jumps, and for an unopened insight that has a
/// handler, also asks the server to remember that it was opened. The card is
/// the list item, so an ask's form, which cannot sit inside a button, is drawn
/// inside the same border under the button.
fn row(item: Item, rail: Rail(message)) -> Element(message) {
  let lifted = item.lifted
  let folded = list.contains(rail.opened, lifted.key)

  html.li(
    [
      attribute.class("lift"),
      attribute.class(state(lifted, folded)),
      attribute.class(kind_class(lifted)),
    ],
    [
      html.button(
        list.flatten([
          [attribute.type_("button"), attribute.class("lift-press")],
          jump(item.target),
          press(lifted, folded, rail.open),
        ]),
        [
          html.span([attribute.class("lift-kind")], [
            html.text(kind_word(lifted)),
          ]),
          source(item.at, source_words(rail, lifted)),
          html.span([attribute.class("lift-head")], [html.text(lifted.head)]),
          decide(lifted, rail.dock),
        ],
      ),
      rail.under(lifted.key),
      acts(rail.offer(lifted)),
    ],
  )
}

/// The card's actions, or nothing when the page offers none. Each button's
/// message was fixed when the page drew it, so a press names no key of its own.
fn acts(offer: Offer(message)) -> Element(message) {
  // The card's last child is always drawn, so its place in the list is fixed.
  case offer {
    NoOffer -> element.none()
    RetryOffer(press:) ->
      html.div([attribute.class("lift-acts")], [
        act("Retry the last step", press),
      ])
    CloseOffer(file:, dismiss:) ->
      html.div([attribute.class("lift-acts")], [
        act("File issue", file),
        act("Dismiss", dismiss),
      ])
    OfferSent ->
      html.div([attribute.class("lift-acts")], [
        html.span([attribute.class("lift-sending")], [html.text("Sending…")]),
      ])
  }
}

/// One action's button.
fn act(label: String, press: message) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("lift-act"),
      event.on_click(press),
    ],
    [html.text(label)],
  )
}

/// The class that names a row's kind, from the closed type and never from
/// session text, so the stylesheet can set an ask's question apart.
fn kind_class(row: Lifted) -> String {
  case row.kind {
    attention.ApprovalPending(..) -> "lift-approval"
    attention.FailedStep | attention.FailedTurn -> "lift-failed"
    attention.SubagentResult(..) -> "lift-result"
    attention.PeerMessage(..) -> "lift-peer"
    attention.AskPending -> "lift-ask"
    attention.StuckStrand(..) -> "lift-stuck"
    attention.FindOpen(..) -> "lift-find"
  }
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

/// The header's words after the kind chip: the time and the source joined by
/// a dot where the row has both, and whichever it has otherwise. Nothing when
/// the row has neither.
fn source(at: Option(Int), from: String) -> Element(message) {
  // An empty header draws no span, so the head follows the kind directly.
  case at, from {
    None, "" -> element.none()
    None, from -> html.span([attribute.class("lift-source")], [html.text(from)])
    Some(at), "" ->
      html.span([attribute.class("lift-source")], [
        stamp.time(at, "lift-time"),
      ])
    Some(at), from ->
      html.span([attribute.class("lift-source")], [
        stamp.time(at, "lift-time"),
        html.text(" · " <> from),
      ])
  }
}

/// The line that says where an approval is decided, or nothing for any other
/// row.
fn decide(row: Lifted, dock: Dock) -> Element(message) {
  // An observer's page has no dock, and says who decides instead.
  case row.kind, dock {
    attention.ApprovalPending(..), InDock ->
      html.span([attribute.class("lift-go"), attribute.class("lift-dock")], [
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
    | attention.AskPending, _
    | attention.StuckStrand(..), _
    | attention.FindOpen(..), _
    -> element.none()
  }
}

/// The word a row's kind is named by, on its chip in the rail and in the tag
/// of its row in the stream.
///
/// ## Examples
///
/// ```gleam
/// // lifted.kind_word(row) == "Ask"
/// ```
pub fn kind_word(row: Lifted) -> String {
  case row.kind {
    attention.ApprovalPending(..) -> "Approval"
    attention.FailedStep -> "Failed"
    attention.FailedTurn -> "Failed"
    attention.SubagentResult(..) -> "Result"
    attention.PeerMessage(..) -> "Peer"
    attention.AskPending -> "Ask"
    attention.StuckStrand(..) -> "Stuck"
    attention.FindOpen(..) -> "Find"
  }
}

/// Where a row came from, or nothing: the tool an approval asks to use, the
/// name of the session that messaged, or the strand on screen for a failure in
/// it. A result names no source, since its child's identity is not for the
/// reader. A session the page does not list is "another session", never its
/// identity. Every part is text the session or the catalogue named, so it is
/// drawn as text only.
fn source_words(rail: Rail(message), row: Lifted) -> String {
  case row.kind {
    attention.ApprovalPending(tool:) -> tool
    attention.SubagentResult(..) -> ""
    attention.PeerMessage(session:, ..) ->
      rail.names(session) |> option.unwrap("another session")
    attention.FailedStep | attention.FailedTurn -> rail.strand
    attention.AskPending -> ""
    attention.StuckStrand(strand:) -> strand
    attention.FindOpen(kind:) -> kind
  }
}

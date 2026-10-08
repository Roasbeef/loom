//// The peer links the Session pane lists, and the one set of changes an
//// owner's page may ask the daemon to make to them (protocol-change/077).
////
//// A peer link is a directional grant: it lets one strand of a session send
//// a message into a strand of another. The terminal lists and changes links
//// with `/peers`, and `loomd peer` does the same from a shell. This module is
//// what the web page shares with them. It holds the vocabulary of the
//// exchange (what the page asks, what the daemon answers and the fixed words
//// for each refusal) and the small state machine of the controls, and nothing
//// that decides what a link may do. The daemon decides that, with the same
//// commands the terminal uses, and decides it again each time it is asked
//// (`client/daemon/ui_socket.peer_links_for`).
////
//// A page never holds owner authority (`ui_relay.capped`), so the page cannot
//// change a link itself. It asks, by value, and the daemon runs the request
//// only for a page whose principal is still the owner. The request names the
//// strand the page shows and the other end's session and strand, which the
//// page drew from the daemon's own list or the owner typed. Nothing in it
//// names the page's own session, which the daemon takes from the attachment.
////
//// Only an owner's page has a control, so only an owner's page ever holds a
//// `Board`. A member's or an observer's page reads nothing and draws nothing,
//// because a row names another session and what that session is called, and
//// a person who may not see that session should not learn it from a link.
////
//// Every name, session and strand in a `Row` is text from the catalogue or
//// from a session, so the view draws each as a text node and never as an
//// attribute, a class or a key.

import gleam/list
import gleam/option.{type Option, None, Some}

/// Whether a link may start an idle strand or only add to a running one.
pub type Wake {
  /// Delivery is allowed only while the receiving strand has an active run.
  BusyOnly

  /// Delivery may start a new run on the receiving strand.
  MayWake
}

/// Where a link came from.
pub type Basis {
  /// The owner granted it, from a terminal or from this page.
  Granted

  /// The daemon's `[peers] default_links` setting supplies it. It exists
  /// while the setting holds and the owner has not unlinked the pair.
  Default
}

/// Which way a link points, from the focused strand.
pub type Direction {
  /// The focused strand may send into the other strand.
  Outgoing

  /// The other strand may send into the focused strand.
  Incoming
}

/// One link of the focused strand, outgoing or incoming.
pub type Row {
  Row(
    /// Whether the focused strand sends (`Outgoing`) or receives (`Incoming`).
    direction: Direction,
    /// The other end's canonical session identity.
    session: String,
    /// The other session's display name from the catalogue, or empty when the
    /// daemon could not read it.
    name: String,
    /// The other end's strand.
    strand: String,
    /// What the link allows, or `None` when the other session is not running
    /// and could not be asked.
    wake: Option(Wake),
    /// Whether the owner granted the link or a default supplies it.
    basis: Basis,
  )
}

/// The focused strand's links as the daemon last read them.
pub type Board {
  Board(
    /// The strand the links belong to, which the page's focus chose.
    strand: String,
    /// Outgoing rows then incoming rows, at most `row_limit`.
    rows: List(Row),
    /// Whether the daemon had rows beyond those it sent.
    omitted: Omitted,
  )
}

/// What a board leaves out.
pub type Omitted {
  /// Every link the daemon read is in the board.
  AllShown

  /// The daemon sent more rows than the board holds, and this many were cut.
  Cut(count: Int)

  /// The daemon said more pages exist and the board did not read them, so no
  /// count is known.
  Unread
}

/// The most rows a board holds. The daemon's reply is bounded by the control
/// frame, and a strand with more links than this still lists the first.
pub const row_limit = 40

/// The strand a link form targets unless the owner types another, and the one
/// a session's default link joins.
pub const default_target = "main"

/// Whether the focused strand already sends to any strand of `session`, by a
/// grant or by the daemon's default link. The board's rows come from the same
/// listing the daemon delivers by, so a default link is in them exactly when
/// delivery admits it, and the page decides nothing of its own. Incoming rows
/// do not count, and neither does the other end's strand.
///
/// ## Examples
///
/// ```gleam
/// assert !peer_links.sends_to(Board("main", [], AllShown), "s")
/// ```
pub fn sends_to(board: Board, session: String) -> Bool {
  list.any(board.rows, fn(row) {
    row.direction == Outgoing && row.session == session
  })
}

/// One link to remove, named from the focused strand's side.
pub type Edge {
  Edge(
    /// Whether the focused strand is the sender or the receiver of the link.
    direction: Direction,
    /// The other end's session.
    session: String,
    /// The other end's strand.
    strand: String,
  )
}

/// Whether a new link also grants the opposite direction in the same action.
/// It is a type and not a flag so the page's state names what it chose.
pub type Reverse {
  /// Only the focused strand's direction is granted.
  OneWay

  /// The other strand is granted the focused strand in return.
  BothWays
}

/// Which directions of a two-way pair an Unlink removes.
pub type Removal {
  /// The direction of the row whose button was pressed.
  ThisWay

  /// The opposite direction, which the pair's other row names.
  OtherWay

  /// Both directions.
  EitherWay
}

/// What the page asks the daemon. It is the whole of what a page may send.
pub type Request {
  /// Lists the strand's links.
  Read(strand: String)

  /// Grants a link from the strand to a strand of another session, and, when
  /// `reverse` is `BothWays`, the opposite link as well.
  Link(
    strand: String,
    session: String,
    target: String,
    wake: Wake,
    reverse: Reverse,
  )

  /// Removes the named links.
  Unlink(strand: String, edges: List(Edge))
}

/// Whether every part of a change took effect.
pub type Outcome {
  /// Everything asked for was done.
  Complete

  /// A link was made or removed on one side only: the first half of a
  /// two-way link, or an unlink whose recipient could not be updated. The
  /// same request can be repeated.
  Partial
}

/// Why the daemon changed nothing, or only part. Every page shows the fixed
/// words for the reason (`reason_words`), never the daemon's own text.
pub type Reason {
  /// The page's principal is not the daemon's owner, or the page has ended.
  /// One answer for both, so a page learns nothing else about its standing.
  NotOwner

  /// A session in the request is not running, so a link to or from it cannot
  /// be made or removed. A saved session has to be opened first.
  NotRunning

  /// The other session has no strand with the typed name.
  MissingStrand

  /// The typed strand is empty, too long, or holds a control character.
  InvalidStrand

  /// The request names the page's own session as the other end.
  SameSession

  /// A strand holds at most 64 outgoing links.
  TooMany

  /// The daemon could not answer: it was starting, stopping or slow, or the
  /// change could not be recorded.
  Unavailable
}

/// The daemon's answer to a request.
pub type Answer {
  /// The strand's links.
  Listed(board: Board)

  /// A link was made or removed. The page reads the strand again.
  Changed(outcome: Outcome)

  /// Nothing was changed.
  Declined(reason: Reason)
}

/// Whether a request is with the daemon.
pub type Asking {
  /// Nothing is outstanding.
  Idle

  /// A request is with the daemon. A press meanwhile is ignored, so one press
  /// asks at most once.
  Waiting
}

/// What the controls are showing, which is the page's own state and nothing
/// the session records.
pub type Step {
  /// The list and its buttons.
  Resting

  /// The Link control is open and asks which session.
  Choosing

  /// A session is chosen and the Link form asks the rest.
  Configuring(
    /// The chosen session, as the page's own list named it.
    session: String,
    /// The name the page's list gave it.
    name: String,
    /// What the new link allows.
    wake: Wake,
    /// Whether the opposite link is granted too.
    reverse: Reverse,
  )

  /// An Unlink question is open for this row.
  Removing(row: Row)
}

/// The line under the list.
pub type Note {
  /// Nothing to say.
  Silent

  /// What a request that changed something did.
  Said(outcome: Outcome)

  /// Why a request changed nothing.
  Refused(reason: Reason)
}

/// A button of the controls. The page's message wraps one, and the
/// component applies it to the controls. Each carries what was drawn on the
/// button and nothing the browser sends: a row is the one the board held when
/// the button was drawn, and the page checks it against the board again.
pub type Press {
  /// Opens the Link control.
  OpenLink

  /// Chooses the session a new link goes to, with the name the page's list
  /// gave it.
  PickSession(session: String, name: String)

  /// Chooses what the new link allows.
  ChooseWake(wake: Wake)

  /// Sets the Both directions toggle.
  ChooseReverse(reverse: Reverse)

  /// Opens the Unlink question for a row.
  AskUnlink(row: Row)

  /// Answers the Unlink question, naming which directions to remove.
  ConfirmUnlink(removal: Removal)

  /// Closes the Link control or the Unlink question without asking.
  Cancel
}

/// What the page's peer-link controls are doing.
pub type Control {
  /// The page's principal cannot manage links, and the page draws nothing. A
  /// member's page and an observer's are always here.
  Withheld

  /// The page's principal is the owner. It draws the list and the controls.
  Offered(
    /// The last list the daemon sent, or `None` before the first.
    board: Option(Board),
    /// Whether a request is outstanding.
    asking: Asking,
    /// What the controls are showing.
    step: Step,
    /// The line under the list.
    note: Note,
  )
}

/// What the page's controls are at the start: drawn and empty for a page that
/// was handed the capability, and withheld for any other.
///
/// ## Examples
///
/// ```gleam
/// assert peer_links.start(capable: False) == peer_links.Withheld
/// ```
pub fn start(capable capable: Bool) -> Control {
  case capable {
    True -> Offered(board: None, asking: Idle, step: Resting, note: Silent)
    False -> Withheld
  }
}

/// The fixed words for a refusal, so nothing the daemon or a session wrote
/// reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert peer_links.reason_words(peer_links.NotOwner)
///   == "Only the owner can change peer links."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotOwner -> "Only the owner can change peer links."
    NotRunning -> "That session is not running. Open it first."
    MissingStrand -> "That session has no strand with that name."
    InvalidStrand -> "Enter a strand name of 1 to 128 characters."
    SameSession -> "Choose a different session."
    TooMany -> "This strand already has the most links it can have."
    Unavailable -> "The daemon could not make that change. Try again."
  }
}

/// The words for a change that took effect, wholly or in part.
///
/// ## Examples
///
/// ```gleam
/// assert peer_links.outcome_words(peer_links.Complete) == "Done."
/// ```
pub fn outcome_words(outcome: Outcome) -> String {
  case outcome {
    Complete -> "Done."
    Partial ->
      "Changed on this side only. The other session could not be updated; try again."
  }
}

/// What a wake permission says in a row's quiet marks.
///
/// ## Examples
///
/// ```gleam
/// assert peer_links.wake_mark(peer_links.MayWake) == Some("may wake")
/// ```
pub fn wake_mark(wake: Option(Wake)) -> Option(String) {
  case wake {
    Some(MayWake) -> Some("may wake")
    Some(BusyOnly) | None -> None
  }
}

/// The opposite of a direction.
///
/// ## Examples
///
/// ```gleam
/// assert peer_links.opposite(peer_links.Outgoing) == peer_links.Incoming
/// ```
pub fn opposite(direction: Direction) -> Direction {
  case direction {
    Outgoing -> Incoming
    Incoming -> Outgoing
  }
}

/// The board the controls last read, if any.
///
/// ## Examples
///
/// ```gleam
/// assert peer_links.board(peer_links.Withheld) == None
/// ```
pub fn board(control: Control) -> Option(Board) {
  case control {
    Withheld -> None
    Offered(board:, ..) -> board
  }
}

/// The row of the opposite direction between the same two strands, when the
/// board holds one: the other half of a two-way pair.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.partner(board, row)
/// ```
pub fn partner(board: Board, row: Row) -> Option(Row) {
  list.find(board.rows, fn(other) {
    other.direction == opposite(row.direction)
    && other.session == row.session
    && other.strand == row.strand
  })
  |> option.from_result
}

/// The links an Unlink of `removal` takes away for `row`, or a refusal when
/// the removal names a direction the board does not hold. `OtherWay` and
/// `EitherWay` need the pair's other row, so a board that changed since the
/// question was drawn cannot remove a link its question did not show.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.edges(board, row, peer_links.EitherWay)
/// ```
pub fn edges(
  board: Board,
  row: Row,
  removal: Removal,
) -> Result(List(Edge), Nil) {
  let this = Edge(row.direction, row.session, row.strand)
  let other = Edge(opposite(row.direction), row.session, row.strand)
  case removal, partner(board, row) {
    ThisWay, _ -> Ok([this])
    OtherWay, Some(_) -> Ok([other])
    EitherWay, Some(_) -> Ok([this, other])
    OtherWay, None | EitherWay, None -> Error(Nil)
  }
}

/// The controls after the owner opens the Link control. It is ignored while a
/// request is outstanding, and from a page with no capability.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.open_link(control)
/// ```
pub fn open_link(control: Control) -> Control {
  case control {
    Offered(asking: Idle, ..) ->
      Offered(..control, step: Choosing, note: Silent)
    Offered(asking: Waiting, ..) | Withheld -> control
  }
}

/// The controls after the owner chose a session for the new link. The new link
/// starts as the narrowest one: busy-only, one way.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.choose(control, "session-id", "review auth")
/// ```
pub fn choose(control: Control, session: String, name: String) -> Control {
  case control {
    Offered(step: Choosing, asking: Idle, ..)
    | Offered(step: Configuring(..), asking: Idle, ..) ->
      Offered(
        ..control,
        step: Configuring(session:, name:, wake: BusyOnly, reverse: OneWay),
        note: Silent,
      )
    Offered(..) | Withheld -> control
  }
}

/// The controls after the wake choice changed. Ignored unless a session is
/// chosen.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.choose_wake(control, peer_links.MayWake)
/// ```
pub fn choose_wake(control: Control, wake: Wake) -> Control {
  case control {
    Offered(step: Configuring(..) as step, asking: Idle, ..) ->
      Offered(..control, step: Configuring(..step, wake:), note: Silent)
    Offered(..) | Withheld -> control
  }
}

/// The controls after the Both directions toggle changed. Ignored unless a
/// session is chosen.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.choose_reverse(control, peer_links.BothWays)
/// ```
pub fn choose_reverse(control: Control, reverse: Reverse) -> Control {
  case control {
    Offered(step: Configuring(..) as step, asking: Idle, ..) ->
      Offered(..control, step: Configuring(..step, reverse:), note: Silent)
    Offered(..) | Withheld -> control
  }
}

/// The controls after the owner pressed Unlink on a row the board holds. The
/// question is for that row as drawn.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.ask_unlink(control, row)
/// ```
pub fn ask_unlink(control: Control, row: Row) -> Control {
  case control {
    Offered(board: Some(held), asking: Idle, ..) ->
      case list.contains(held.rows, row) {
        True -> Offered(..control, step: Removing(row), note: Silent)
        False -> control
      }
    Offered(..) | Withheld -> control
  }
}

/// The controls after the owner closed the Link control or the Unlink
/// question without asking.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.cancel(control)
/// ```
pub fn cancel(control: Control) -> Control {
  case control {
    Offered(asking: Idle, ..) -> Offered(..control, step: Resting, note: Silent)
    Offered(asking: Waiting, ..) | Withheld -> control
  }
}

/// The controls after the page sent a request.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.waiting(control)
/// ```
pub fn waiting(control: Control) -> Control {
  case control {
    Offered(..) -> Offered(..control, asking: Waiting)
    Withheld -> control
  }
}

/// Whether the page may send a read now: it is offered, nothing is
/// outstanding, and the board is missing or belongs to another strand.
///
/// ## Examples
///
/// ```gleam
/// assert peer_links.stale(peer_links.start(capable: True), "main")
/// ```
pub fn stale(control: Control, strand: String) -> Bool {
  case control {
    Offered(board: None, asking: Idle, ..) -> True
    Offered(board: Some(held), asking: Idle, ..) -> held.strand != strand
    Offered(asking: Waiting, ..) | Withheld -> False
  }
}

/// The controls after the daemon answered. A list replaces the board and
/// leaves the owner's open control alone, so a refresh does not close a
/// question. A change closes whatever it answered and leaves the board stale
/// for the read that follows.
///
/// ## Examples
///
/// ```gleam
/// // peer_links.answered(control, peer_links.Declined(peer_links.NotOwner))
/// ```
pub fn answered(control: Control, answer: Answer) -> Control {
  case control, answer {
    Withheld, _ -> Withheld
    Offered(..), Listed(board:) ->
      Offered(..control, board: Some(board), asking: Idle)
    Offered(..), Changed(outcome:) ->
      Offered(..control, asking: Idle, step: Resting, note: Said(outcome))
    Offered(..), Declined(reason:) ->
      Offered(..control, asking: Idle, note: Refused(reason))
  }
}

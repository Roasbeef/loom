//// The page's remembered-permissions list: what the page holds between
//// reads, the two-step forget, and the vocabulary the daemon's sign-in check
//// shares with it (protocol-change/073).
////
//// "Allow for this session" is a decision that outlives the page that made
//// it, and a page can be opened from a stolen cookie. So an operator's page
//// lists what the session remembers, says who allowed each permission and
//// when, and lets them forget it. The list itself is `session_view/remembered`
//// (the daemon's board, decoded totally, and the words both hosts share); this
//// module is the page's own part.
////
//// Forgetting is two presses. The first arms a question for one row (or for
//// all of them) and sends nothing. What it arms is the request as the list
//// looked when it was drawn, with the sequence that list carried, and the
//// second press sends exactly that, so a permission remembered after the list
//// was drawn is never forgotten by a press that never saw it: the daemon
//// refuses the stale sequence and the page reads again.
////
//// A permission granted from a browser sign-in is annotated when that sign-in
//// has since ended, so an owner who signed a browser out can see what it left
//// behind. Only the daemon can say whether a sign-in stands, and it says it
//// only to a page that may ask (`Transport.logins`): the answer is the logins
//// that have ended, and a login the daemon could not judge is not among them.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/remembered

/// How long a list stands before the page reads it again, in milliseconds of
/// the transport's clock. The list changes only when an operator allows or
/// forgets something for the session, so the page reads when it opens, after
/// it has answered an approval, and no more often than this otherwise.
pub const refresh_ms = 30_000

/// A browser sign-in a remembered permission was allowed from: the principal
/// who held it and its fingerprint. Neither is a credential.
pub type Login {
  Login(principal: String, fingerprint: String)
}

/// One forget the page has asked the question for and not yet sent: the row it
/// is for, which the view reads to draw the question in that row's place, and
/// the request exactly as the list carried it.
pub type Armed {
  Armed(key: String, forget: remembered.Forget)
}

/// What the page holds about the list besides the board, which is part of the
/// session's shared record.
pub type State {
  State(
    /// When the page last wanted the list, on the transport's clock.
    asked_at: Option(Int),
    /// The question that is open, if one is.
    armed: Option(Armed),
    /// The sign-ins the daemon said have ended.
    ended: List(Login),
  )
}

/// A page that has read nothing and asked nothing.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.new().armed == None
/// ```
pub fn new() -> State {
  State(asked_at: None, armed: None, ended: [])
}

/// Whether the page should want the list at `at`: when it never has, or last
/// did `refresh_ms` or more ago.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.due(remembered.new(), 0)
/// ```
pub fn due(state: State, at: Int) -> Bool {
  case state.asked_at {
    Some(before) -> at - before >= refresh_ms
    None -> True
  }
}

/// Records that the page wanted the list at `at`.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.wanted(remembered.new(), 5).asked_at == Some(5)
/// ```
pub fn wanted(state: State, at: Int) -> State {
  State(..state, asked_at: Some(at))
}

/// Opens a question, replacing any other: only one row asks at a time.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.arm(remembered.new(), armed).armed == Some(armed)
/// ```
pub fn arm(state: State, armed: Armed) -> State {
  State(..state, armed: Some(armed))
}

/// Closes the question without sending anything.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.disarm(remembered.new()).armed == None
/// ```
pub fn disarm(state: State) -> State {
  State(..state, armed: None)
}

/// Takes the daemon's answer to which sign-ins have ended.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.judged(remembered.new(), []).ended == []
/// ```
pub fn judged(state: State, ended: List(Login)) -> State {
  State(..state, ended:)
}

/// The identity a row's question is drawn under: its kind and what it names,
/// never a position in the list, so a list that is read again between the
/// press and the draw leaves the question on the row it was asked for.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.permission_key(remembered.Readable("/repo")) == "read:/repo"
/// ```
pub fn permission_key(kind: remembered.Kind) -> String {
  case kind {
    remembered.Readable(path:) -> "read:" <> path
    remembered.Writable(path:) -> "write:" <> path
    remembered.FullNetwork -> "network"
    remembered.Unrecognized(kind:) -> "other:" <> kind
  }
}

/// The identity of a consent's row.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.consent_key("ab12") == "action:ab12"
/// ```
pub fn consent_key(id: String) -> String {
  "action:" <> id
}

/// The identity of the question that asks about everything.
pub const everything_key = "all"

/// The question for one permission, as the list that carries it draws it.
///
/// ## Examples
///
/// ```gleam
/// // remembered.forgetting_permission(board, permission)
/// ```
pub fn forgetting_permission(
  board: remembered.Board,
  permission: remembered.Permission,
) -> Armed {
  Armed(
    key: permission_key(permission.kind),
    forget: remembered.ForgetPermission(wire: permission.wire, seq: board.seq),
  )
}

/// The question for one consent.
///
/// ## Examples
///
/// ```gleam
/// // remembered.forgetting_consent(consent)
/// ```
pub fn forgetting_consent(consent: remembered.Consent) -> Armed {
  Armed(
    key: consent_key(consent.id),
    forget: remembered.ForgetConsent(id: consent.id, seq: consent.seq),
  )
}

/// The question for everything the list shows.
///
/// ## Examples
///
/// ```gleam
/// // remembered.forgetting_everything(board)
/// ```
pub fn forgetting_everything(board: remembered.Board) -> Armed {
  Armed(
    key: everything_key,
    forget: remembered.ForgetEverything(seq: board.seq),
  )
}

/// The distinct browser sign-ins the board's rows were allowed from, which is
/// what the page asks the daemon about.
///
/// ## Examples
///
/// ```gleam
/// assert remembered.logins(remembered.Board(None, [], [])) == []
/// ```
pub fn logins(board: remembered.Board) -> List(Login) {
  let provenances =
    list.append(
      list.map(board.grants, fn(permission) { permission.provenance }),
      list.map(board.actions, fn(consent) { consent.provenance }),
    )
  list.filter_map(provenances, fn(provenance) {
    case remembered.login(provenance) {
      Some(#(principal, fingerprint)) -> Ok(Login(principal:, fingerprint:))
      None -> Error(Nil)
    }
  })
  |> list.unique
}

/// Whether the sign-in a provenance names is one the daemon said has ended.
///
/// ## Examples
///
/// ```gleam
/// assert !remembered.ended(remembered.new(), remembered.Unknown)
/// ```
pub fn ended(state: State, provenance: remembered.Provenance) -> Bool {
  case remembered.login(provenance) {
    Some(#(principal, fingerprint)) ->
      list.contains(state.ended, Login(principal:, fingerprint:))
    None -> False
  }
}

/// The words of the note under a permission whose sign-in has ended.
pub const ended_words =
  "The browser sign-in this came from has since ended. Forget it if you do not recognise it."

/// The count in a button's label: "Forget all 3".
///
/// ## Examples
///
/// ```gleam
/// assert remembered.forget_all_label(3) == "Forget all 3"
/// ```
pub fn forget_all_label(count: Int) -> String {
  "Forget all " <> int.to_string(count)
}

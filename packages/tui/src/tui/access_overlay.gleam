//// The owner's `/access` overlay (protocol-change/053, phase 3).
////
//// The overlay lists the daemon's principals with their credential state,
//// drills into one principal's memberships, and can do three things that only
//// reduce or move access: set a member's role in one session, revoke one
//// membership, and revoke a member's credentials. Each change is reviewed
//// with a y/N question before it is sent, and each goes through the same
//// control commands `loom access` uses.
////
//// The overlay never grants. An invitation or a rotation prints a claim, and
//// the terminal records every key, paste and socket message when it runs with
//// `--record`, so a claim shown or typed here would need a redaction rule to
//// stay out of that file. For those two the overlay shows the `loom access`
//// line and stops there; the one-shot command is the only process that ever
//// receives a claim. Nothing the overlay draws is a secret: a credential
//// appears as the daemon's 16-character fingerprint, and the rows are the
//// ones `host/access` accepts for `loom access list`.
////
//// The overlay is a pure state machine. `update` maps a key to an `Action`
//// that carries the next state, and `tui/session_control` turns a read or a
//// change into a control job and feeds the reply back through `listed`,
//// `memberships_listed`, `changed` and `failed`. Whether the connection is
//// the owner's is the daemon's judgment, not the terminal's: a member who
//// opens the overlay receives `forbidden`, and `failed` turns that one
//// refusal into a sentence saying the overlay is for the owner.

import core/json.{type JsonValue}
import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/access
import session_view/text_hygiene
import tui/daemon/protocol.{type MemberRole, ObserverRole, OperatorRole}
import tui/theme

/// Whether a listed principal is the daemon's owner or a member.
pub type Kind {
  /// The owner. Its credential is the owner token, which this overlay does
  /// not manage, and it holds no memberships.
  Owner

  /// A principal an invitation created.
  Member
}

/// What the daemon reports about a principal's credential. It never carries
/// the credential itself.
pub type Credential {
  /// A credential is bound.
  Active(
    /// The first 16 hexadecimal characters of the credential's digest.
    fingerprint: String,
    /// When the credential was bound by a claim, in wall-clock milliseconds.
    /// Absent for one that was enrolled by digest.
    claimed_at_ms: Option(Int),
  )

  /// An invitation or rotation is waiting to be redeemed.
  ClaimOpen(
    /// How long the claim stays redeemable, in milliseconds.
    expires_in_ms: Int,
  )

  /// The only claim expired unredeemed, and no credential is bound.
  ClaimExpired

  /// Neither a credential nor a claim.
  NoCredential
}

/// One row of `principals.list`.
pub type Principal {
  Principal(
    /// The principal's stable identifier, the argument of every command.
    id: String,
    /// The display name the owner chose at invitation.
    name: String,
    /// Owner or member.
    kind: Kind,
    /// The state of its credential.
    credential: Credential,
  )
}

/// One row of `principals.memberships`.
pub type Membership {
  Membership(
    /// The session the principal holds a role in.
    session_id: String,
    /// The session's current display name.
    name: String,
    /// The role held there.
    role: MemberRole,
  )
}

/// A checked page of principals and the cursor for the page after it.
pub type PrincipalPage {
  PrincipalPage(
    /// Rows in the daemon's order.
    principals: List(Principal),
    /// The last principal on this page when another page exists.
    next: Option(String),
  )
}

/// A checked page of one principal's memberships.
pub type MembershipPage {
  MembershipPage(
    /// Rows in the daemon's order.
    memberships: List(Membership),
    /// The last session on this page when another page exists.
    next: Option(String),
  )
}

/// What the list under the cursor shows.
pub type Focus {
  /// Every principal, one page at a time.
  ListingPrincipals

  /// The memberships of the principal that was opened.
  ListingMemberships(
    /// The principal as it was listed when the operator opened it.
    principal: Principal,
  )
}

/// The question in front of the operator, if any.
pub type Prompt {
  /// Moving through rows; no question is pending.
  Browsing

  /// A change is proposed and waits for `y`.
  Reviewing(
    /// Exactly what will be sent, with the names shown to the operator.
    change: Change,
  )

  /// A command the operator must run in a shell instead.
  ShowingCommand(
    /// The `loom access` line, without any secret.
    line: String,
  )
}

/// One change the overlay can send, with the names it showed for review.
pub type Change {
  /// Sets a member's role in one session.
  SetRole(
    /// The session whose membership changes.
    session_id: String,
    /// The session's display name.
    session_name: String,
    /// The member whose role changes.
    principal_id: String,
    /// The member's display name.
    principal_name: String,
    /// The role held afterwards.
    role: MemberRole,
  )

  /// Removes a member's role in one session.
  RevokeMembership(
    /// The session the member leaves.
    session_id: String,
    /// The session's display name.
    session_name: String,
    /// The member who leaves it.
    principal_id: String,
    /// The member's display name.
    principal_name: String,
  )

  /// Revokes every credential of a member, and any open claim.
  RevokeCredentials(
    /// The member whose credentials are revoked.
    principal_id: String,
    /// The member's display name.
    principal_name: String,
  )
}

/// Modal state owned by the terminal until close.
pub type State {
  State(
    /// Principals read so far, in the daemon's order.
    principals: List(Principal),
    /// Cursor for the next page of principals.
    principals_next: Option(String),
    /// Index of the highlighted principal.
    selected_principal: Int,
    /// Memberships of the opened principal read so far.
    memberships: List(Membership),
    /// Cursor for the next page of memberships.
    memberships_next: Option(String),
    /// Index of the highlighted membership.
    selected_membership: Int,
    /// Which list the cursor is in.
    focus: Focus,
    /// The pending question, if any.
    prompt: Prompt,
    /// The change whose request is outstanding, kept so its acknowledgement
    /// can be checked against what the operator reviewed.
    sending: Option(Change),
    /// The last refusal or hint, shown under the rows.
    notice: String,
    /// The acknowledgement of the last change, kept until the next key.
    outcome: Option(String),
  )
}

/// What one key asks the terminal to do.
pub type Action {
  /// Keep the overlay open with this state.
  Continue(state: State)

  /// Close the overlay.
  Close

  /// Read a page of principals.
  ReadPrincipals(
    /// The state to show while the read runs.
    state: State,
    /// The cursor to read after, absent for the first page.
    after: Option(String),
  )

  /// Read a page of one principal's memberships.
  ReadMemberships(
    /// The state to show while the read runs.
    state: State,
    /// The principal whose memberships are read.
    principal: String,
    /// The cursor to read after, absent for the first page.
    after: Option(String),
  )

  /// Send one reviewed change.
  Apply(
    /// The state to show while the request runs; the review is over.
    state: State,
    /// The change to send.
    change: Change,
  )
}

/// Opens the overlay on its first, still empty, page of principals.
///
/// ## Examples
///
/// ```gleam
/// let state = access_overlay.new()
/// ```
pub fn new() -> State {
  State(
    principals: [],
    principals_next: None,
    selected_principal: 0,
    memberships: [],
    memberships_next: None,
    selected_membership: 0,
    focus: ListingPrincipals,
    prompt: Browsing,
    sending: None,
    notice: "loading principals",
    outcome: None,
  )
}

// A key reduced to what the overlay's four prompts distinguish. Only the
// listed characters mean anything, and folding every other key into
// `Unhandled` here is what keeps each prompt's own `case` to a handful of
// arms.
type Input {
  Cancel
  Accept
  Previous
  Following
  Letter(String)
  Unhandled
}

fn classify(key: keys.Key) -> Input {
  case key {
    keys.Escape -> Cancel
    keys.Enter -> Accept
    keys.Up -> Previous
    keys.Down -> Following
    keys.Char(character) -> Letter(character)
    keys.Backspace
    | keys.Left
    | keys.Right
    | keys.Delete
    | keys.Tab
    | keys.BackTab
    | keys.PageUp
    | keys.PageDown
    | keys.Home
    | keys.End
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Unknown(_) -> Unhandled
  }
}

/// Applies one key while the overlay owns the keyboard.
///
/// ## Examples
///
/// ```gleam
/// let action = access_overlay.update(keys.Char("r"), state)
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  let state = State(..state, outcome: None)
  let input = classify(key)
  case state.sending, input {
    // While a change is outstanding no second one can be proposed, so its
    // acknowledgement is always checked against the change it answers.
    Some(_), Accept | Some(_), Letter(_) ->
      Continue(State(..state, notice: "waiting for the daemon's answer"))
    Some(_), Cancel
    | Some(_), Previous
    | Some(_), Following
    | Some(_), Unhandled
    | None, _
    -> dispatch(state, input)
  }
}

fn dispatch(state: State, input: Input) -> Action {
  case state.prompt, input {
    Reviewing(change), input -> review(change, input, state)
    ShowingCommand(_), Cancel | ShowingCommand(_), Accept ->
      Continue(State(..state, prompt: Browsing, notice: ""))
    ShowingCommand(_), Previous
    | ShowingCommand(_), Following
    | ShowingCommand(_), Letter(_)
    | ShowingCommand(_), Unhandled
    -> Continue(state)
    Browsing, input ->
      case state.focus {
        ListingPrincipals -> browse_principals(input, state)
        ListingMemberships(principal) ->
          browse_memberships(input, state, principal)
      }
  }
}

// The y/N question. Only a lowercase `y` sends; Escape and `n` decline, and
// every other key leaves the question open, so a stray key or a held Enter
// cannot confirm. The state handed to `Apply` has the review closed, which is
// what keeps a second `y` from sending the same change twice.
fn review(change: Change, input: Input, state: State) -> Action {
  case input {
    Letter("y") ->
      Apply(
        State(
          ..state,
          prompt: Browsing,
          sending: Some(change),
          notice: "sending the change",
        ),
        change,
      )
    Cancel | Letter("n") ->
      Continue(State(..state, prompt: Browsing, notice: "change cancelled"))
    Accept | Previous | Following | Letter(_) | Unhandled -> Continue(state)
  }
}

fn browse_principals(input: Input, state: State) -> Action {
  case input {
    Cancel -> Close
    Previous ->
      Continue(
        State(
          ..state,
          selected_principal: wrap_up(
            state.selected_principal,
            state.principals,
          ),
        ),
      )
    Following ->
      Continue(
        State(
          ..state,
          selected_principal: wrap_down(
            state.selected_principal,
            state.principals,
          ),
        ),
      )
    Accept -> open_principal(state)
    Letter("r") -> ReadPrincipals(refreshing(state), None)
    Letter("n") ->
      case state.principals_next {
        Some(cursor) ->
          ReadPrincipals(
            State(..state, notice: "loading more principals"),
            Some(cursor),
          )
        None -> Continue(State(..state, notice: "no more principals"))
      }
    Letter("c") -> propose_credentials(state, selected_principal(state))
    Letter("i") ->
      Continue(State(..state, prompt: ShowingCommand(access.invite_line(""))))
    Letter("t") -> propose_rotation(state, selected_principal(state))
    Letter(_) | Unhandled -> Continue(state)
  }
}

fn open_principal(state: State) -> Action {
  case selected_principal(state) {
    Ok(principal) ->
      ReadMemberships(
        State(
          ..state,
          focus: ListingMemberships(principal),
          memberships: [],
          memberships_next: None,
          selected_membership: 0,
          notice: "loading memberships",
        ),
        principal.id,
        None,
      )
    Error(Nil) -> Continue(State(..state, notice: "no principal is selected"))
  }
}

fn browse_memberships(
  input: Input,
  state: State,
  principal: Principal,
) -> Action {
  case input {
    Cancel -> Continue(State(..state, focus: ListingPrincipals, notice: ""))
    Previous ->
      Continue(
        State(
          ..state,
          selected_membership: wrap_up(
            state.selected_membership,
            state.memberships,
          ),
        ),
      )
    Following ->
      Continue(
        State(
          ..state,
          selected_membership: wrap_down(
            state.selected_membership,
            state.memberships,
          ),
        ),
      )
    Accept -> Continue(state)
    Letter("r") -> ReadMemberships(refreshing(state), principal.id, None)
    Letter("n") ->
      case state.memberships_next {
        Some(cursor) ->
          ReadMemberships(
            State(..state, notice: "loading more memberships"),
            principal.id,
            Some(cursor),
          )
        None -> Continue(State(..state, notice: "no more memberships"))
      }
    Letter("o") -> propose_role(state, principal, OperatorRole)
    Letter("b") -> propose_role(state, principal, ObserverRole)
    Letter("d") -> propose_revocation(state, principal)
    Letter("c") -> propose_credentials(state, Ok(principal))
    Letter("i") ->
      Continue(
        State(
          ..state,
          prompt: ShowingCommand(access.invite_line(selected_session(state))),
        ),
      )
    Letter("t") -> propose_rotation(state, Ok(principal))
    Letter(_) | Unhandled -> Continue(state)
  }
}

fn refreshing(state: State) -> State {
  State(..state, notice: "refreshing")
}

// A role change is refused here when the member already holds the role, since
// the daemon would accept it as a no-op and the operator would read the
// acknowledgement as a change.
fn propose_role(
  state: State,
  principal: Principal,
  role: MemberRole,
) -> Action {
  case selected_membership(state) {
    Ok(membership) if membership.role == role ->
      Continue(
        State(
          ..state,
          notice: principal.name
            <> " already holds that role in "
            <> membership.name,
        ),
      )
    Ok(membership) ->
      Continue(
        State(
          ..state,
          prompt: Reviewing(SetRole(
            session_id: membership.session_id,
            session_name: membership.name,
            principal_id: principal.id,
            principal_name: principal.name,
            role:,
          )),
          notice: "",
        ),
      )
    Error(Nil) -> Continue(State(..state, notice: "select a membership first"))
  }
}

fn propose_revocation(state: State, principal: Principal) -> Action {
  case selected_membership(state) {
    Ok(membership) ->
      Continue(
        State(
          ..state,
          prompt: Reviewing(RevokeMembership(
            session_id: membership.session_id,
            session_name: membership.name,
            principal_id: principal.id,
            principal_name: principal.name,
          )),
          notice: "",
        ),
      )
    Error(Nil) -> Continue(State(..state, notice: "select a membership first"))
  }
}

// The owner's credential is the owner token. Revoking it through the control
// socket that the token authenticates would lock the owner out of the daemon
// they are administering, and the command exists for members, so the overlay
// declines to propose it.
fn propose_credentials(state: State, chosen: Result(Principal, Nil)) -> Action {
  case chosen {
    Ok(Principal(kind: Owner, ..)) ->
      Continue(
        State(..state, notice: "the owner's credential is not managed here"),
      )
    Ok(principal) ->
      Continue(
        State(
          ..state,
          prompt: Reviewing(RevokeCredentials(principal.id, principal.name)),
          notice: "",
        ),
      )
    Error(Nil) -> Continue(State(..state, notice: "no principal is selected"))
  }
}

fn propose_rotation(state: State, chosen: Result(Principal, Nil)) -> Action {
  case chosen {
    Ok(Principal(kind: Owner, ..)) ->
      Continue(
        State(..state, notice: "the owner's credential is not rotated here"),
      )
    Ok(principal) ->
      Continue(
        State(
          ..state,
          prompt: ShowingCommand(access.rotate_line(principal.id)),
          notice: "",
        ),
      )
    Error(Nil) -> Continue(State(..state, notice: "no principal is selected"))
  }
}

// The first page again, in the list the change touched. A role or membership
// change re-reads the opened principal's memberships. A credential change
// re-reads the principals and returns to that list, since the credential state
// is what changed and it is shown there.
fn reload(state: State, change: Change) -> Action {
  case change, state.focus {
    SetRole(..), ListingMemberships(principal)
    | RevokeMembership(..), ListingMemberships(principal)
    -> ReadMemberships(state, principal.id, None)
    RevokeCredentials(..), ListingMemberships(_)
    | RevokeCredentials(..), ListingPrincipals
    -> ReadPrincipals(State(..state, focus: ListingPrincipals), None)
    SetRole(..), ListingPrincipals | RevokeMembership(..), ListingPrincipals ->
      ReadPrincipals(state, None)
  }
}

/// Decodes one `principals.list` reply through `host/access`, the check `loom
/// access list` prints through, so the overlay accepts exactly those rows.
///
/// ## Examples
///
/// ```gleam
/// let page = access_overlay.decode_principals(document)
/// ```
pub fn decode_principals(document: JsonValue) -> Result(PrincipalPage, String) {
  use lines <- result.try(access.principal_lines(document))
  let #(rows, next) = split_cursor(lines)
  use principals <- result.map(list.try_map(rows, principal_row))
  PrincipalPage(principals:, next:)
}

/// Decodes one `principals.memberships` reply for `principal`.
///
/// A reply that names another principal is an error, so a late answer cannot
/// be drawn under the wrong one.
///
/// ## Examples
///
/// ```gleam
/// let page = access_overlay.decode_memberships(document, "alice")
/// ```
pub fn decode_memberships(
  document: JsonValue,
  principal: String,
) -> Result(MembershipPage, String) {
  use lines <- result.try(access.membership_lines(document, principal))
  let #(rows, next) = split_cursor(lines)
  use memberships <- result.map(list.try_map(rows, membership_row))
  MembershipPage(memberships:, next:)
}

// `host/access` ends a page with `{"next": CURSOR}` when another follows. The
// rows before it have been checked; the cursor line is separated here.
fn split_cursor(lines: List(JsonValue)) -> #(List(JsonValue), Option(String)) {
  list.fold(lines, #([], None), fn(found, line) {
    let #(rows, next) = found
    case line {
      json.Object([#("next", json.String(cursor))]) -> #(rows, Some(cursor))
      json.Object(_)
      | json.Array(_)
      | json.String(_)
      | json.Int(_)
      | json.Bool(_)
      | json.Float(_)
      | json.Null -> #(list.append(rows, [line]), next)
    }
  })
}

fn principal_row(row: JsonValue) -> Result(Principal, String) {
  use fields <- result.try(fields_of(row))
  use id <- result.try(text_at(fields, "principal_id"))
  use name <- result.try(text_at(fields, "name"))
  use kind <- result.try(case text_at(fields, "kind") {
    Ok("owner") -> Ok(Owner)
    Ok("member") -> Ok(Member)
    Ok(_) | Error(_) -> Error("invalid principal kind")
  })
  use credential <- result.try(case list.key_find(fields, "credential") {
    Ok(value) -> credential_of(value)
    Error(Nil) -> Error("missing credential state")
  })
  Ok(Principal(id:, name:, kind:, credential:))
}

fn credential_of(value: JsonValue) -> Result(Credential, String) {
  use fields <- result.try(fields_of(value))
  use state <- result.try(text_at(fields, "state"))
  case state {
    "active" -> {
      use fingerprint <- result.map(text_at(fields, "fingerprint"))
      let claimed_at_ms = case list.key_find(fields, "claimed_at_ms") {
        Ok(json.Int(at)) -> Some(at)
        Ok(_) | Error(Nil) -> None
      }
      Active(fingerprint:, claimed_at_ms:)
    }
    "claim_open" ->
      case list.key_find(fields, "expires_in_ms") {
        Ok(json.Int(ms)) -> Ok(ClaimOpen(ms))
        Ok(_) | Error(Nil) -> Error("invalid claim lifetime")
      }
    "claim_expired" -> Ok(ClaimExpired)
    "none" -> Ok(NoCredential)
    _ -> Error("unknown credential state")
  }
}

fn membership_row(row: JsonValue) -> Result(Membership, String) {
  use fields <- result.try(fields_of(row))
  use session_id <- result.try(text_at(fields, "session_id"))
  use name <- result.try(text_at(fields, "name"))
  use role <- result.try(case text_at(fields, "role") {
    Ok("operator") -> Ok(OperatorRole)
    Ok("observer") -> Ok(ObserverRole)
    Ok(_) | Error(_) -> Error("invalid membership role")
  })
  Ok(Membership(session_id:, name:, role:))
}

fn fields_of(value: JsonValue) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected an access row")
  }
}

fn text_at(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) | Error(Nil) -> Error("missing " <> key)
  }
}

/// Files one page of principals. The first page replaces the list; a later
/// page is appended, replacing a row that moved across the cursor.
///
/// ## Examples
///
/// ```gleam
/// let state = access_overlay.listed(state, page, None)
/// ```
pub fn listed(
  state: State,
  page: PrincipalPage,
  after: Option(String),
) -> State {
  let principals = case after {
    None -> page.principals
    Some(_) -> merge(state.principals, page.principals, fn(row) { row.id })
  }
  State(
    ..state,
    principals:,
    principals_next: page.next,
    selected_principal: clamp(state.selected_principal, principals),
    notice: paging_notice(page.next, "principals"),
  )
}

/// Files one page of the opened principal's memberships. A page for any
/// other principal, such as a reply that outlived a Escape, is dropped.
///
/// ## Examples
///
/// ```gleam
/// let state = access_overlay.memberships_listed(state, "alice", page, None)
/// ```
pub fn memberships_listed(
  state: State,
  principal: String,
  page: MembershipPage,
  after: Option(String),
) -> State {
  case state.focus {
    ListingMemberships(opened) if opened.id == principal -> {
      let memberships = case after {
        None -> page.memberships
        Some(_) ->
          merge(state.memberships, page.memberships, fn(row) { row.session_id })
      }
      State(
        ..state,
        memberships:,
        memberships_next: page.next,
        selected_membership: clamp(state.selected_membership, memberships),
        notice: paging_notice(page.next, "memberships"),
      )
    }
    ListingMemberships(_) | ListingPrincipals -> state
  }
}

fn paging_notice(next: Option(String), what: String) -> String {
  case next {
    Some(_) -> "more " <> what <> " available · press n to continue"
    None -> ""
  }
}

// Appends rows whose identity is new and replaces those already held, so a
// row that moved across a cursor boundary between two reads shows once.
fn merge(
  held: List(a),
  incoming: List(a),
  identity: fn(a) -> String,
) -> List(a) {
  list.fold(incoming, held, fn(rows, row) {
    case list.any(rows, fn(held_row) { identity(held_row) == identity(row) }) {
      True ->
        list.map(rows, fn(held_row) {
          case identity(held_row) == identity(row) {
            True -> row
            False -> held_row
          }
        })
      False -> list.append(rows, [row])
    }
  })
}

/// Records the daemon's acknowledgement of the change that was sent and asks
/// for the read that shows its effect.
///
/// The acknowledgement is drawn from what the operator reviewed. The reply's
/// `principal_id` is checked against it, and a reply naming another principal
/// is reported instead of trusted, though the change was still sent. An
/// acknowledgement with no change outstanding, such as one that outlived a
/// close and reopen, is dropped.
///
/// ## Examples
///
/// ```gleam
/// let action = access_overlay.changed(state, document)
/// ```
pub fn changed(state: State, document: JsonValue) -> Action {
  case state.sending {
    None -> Continue(state)
    Some(change) -> {
      let acknowledged = case document {
        json.Object(fields) ->
          list.key_find(fields, "principal_id")
          == Ok(json.String(principal_of(change)))
        json.Array(_)
        | json.String(_)
        | json.Int(_)
        | json.Float(_)
        | json.Bool(_)
        | json.Null -> False
      }
      let settled = State(..state, sending: None, prompt: Browsing)
      reload(
        case acknowledged {
          True ->
            State(
              ..settled,
              outcome: Some(describe(change)),
              notice: "refreshing",
            )
          False ->
            State(
              ..settled,
              outcome: None,
              notice: "the daemon acknowledged a different principal · refreshing",
            )
        },
        change,
      )
    }
  }
}

fn principal_of(change: Change) -> String {
  case change {
    SetRole(principal_id:, ..)
    | RevokeMembership(principal_id:, ..)
    | RevokeCredentials(principal_id:, ..) -> principal_id
  }
}

fn describe(change: Change) -> String {
  case change {
    SetRole(principal_name:, session_name:, role:, ..) ->
      "set "
      <> principal_name
      <> " to "
      <> role_label(role)
      <> " in "
      <> session_name
    RevokeMembership(principal_name:, session_name:, ..) ->
      "revoked " <> principal_name <> "'s access to " <> session_name
    RevokeCredentials(principal_name:, ..) ->
      "revoked " <> principal_name <> "'s credentials"
  }
}

/// Keeps a refusal or an unknown outcome visible under the rows.
///
/// A `forbidden` refusal means the connection is not the owner's, and reads
/// as one sentence saying so. A lost reply to a change leaves its outcome
/// unknown; the notice says to refresh with `r` before trying again, since
/// nothing is resent.
///
/// ## Examples
///
/// ```gleam
/// let state = access_overlay.failed(state, "forbidden: owner only")
/// ```
pub fn failed(state: State, reason: String) -> State {
  let notice = case string.starts_with(reason, "forbidden") {
    True -> "the access overlay is for the owner; this connection is not"
    False ->
      case string.starts_with(reason, "unknown outcome") {
        True -> reason <> " · press r to see the current state"
        False -> "access request refused: " <> reason
      }
  }
  State(..state, prompt: Browsing, sending: None, notice:)
}

// The rows under the cursor, or `Error(Nil)` when a list is empty.
fn selected_principal(state: State) -> Result(Principal, Nil) {
  state.principals |> list.drop(state.selected_principal) |> list.first
}

fn selected_membership(state: State) -> Result(Membership, Nil) {
  state.memberships |> list.drop(state.selected_membership) |> list.first
}

// The highlighted membership's session, for an invitation line that names
// it, or empty when there is none.
fn selected_session(state: State) -> String {
  case selected_membership(state) {
    Ok(membership) -> membership.session_id
    Error(Nil) -> ""
  }
}

fn wrap_up(index: Int, rows: List(a)) -> Int {
  case list.length(rows) {
    0 -> 0
    count if index <= 0 -> count - 1
    _ -> index - 1
  }
}

fn wrap_down(index: Int, rows: List(a)) -> Int {
  case list.length(rows) {
    0 -> 0
    count if index >= count - 1 -> 0
    _ -> index + 1
  }
}

fn clamp(index: Int, rows: List(a)) -> Int {
  int.max(0, int.min(index, list.length(rows) - 1))
}

/// Draws the overlay: a list, its footer, and the pending question if any.
///
/// ## Examples
///
/// ```gleam
/// let frame = access_overlay.render(buffer, screen, state)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, state: State) -> buffer.Buffer {
  let width = int.max(1, int.min(88, screen.size.width - 4))
  let desired = list.length(render_lines(state, width - 2, 1000)) + 2
  let height = int.max(7, int.min(int.min(desired, 22), screen.size.height - 2))
  let area = geometry.centered_rect(width, height, screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [span.span_styled(" ACCESS ", theme.overlay_signal())],
      block.Top,
    )
  let inside = block.inner(area, frame)
  let lines = render_lines(state, inside.size.width, inside.size.height)
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_styled(inside, lines)
}

fn render_lines(state: State, width: Int, height: Int) {
  let footers = footer_lines(state, width)
  let room = int.max(0, height - list.length(footers))
  let content = case state.prompt, state.focus {
    Reviewing(change), _ -> review_lines(change, width)
    ShowingCommand(line), _ -> command_lines(line, width)
    Browsing, ListingPrincipals -> principal_lines(state, width)
    Browsing, ListingMemberships(principal) ->
      membership_lines(state, principal, width)
  }
  let visible = case state.prompt, state.focus {
    Browsing, ListingPrincipals ->
      row_viewport(content, state.selected_principal, 3, 2, room)
    Browsing, ListingMemberships(_) ->
      row_viewport(content, state.selected_membership, 2, 2, room)
    Reviewing(_), _ | ShowingCommand(_), _ -> list.take(content, room)
  }
  list.append(visible, footers)
}

fn footer_lines(state: State, width: Int) {
  let keys = case state.prompt, state.focus {
    Reviewing(_), _ -> "y confirm · n or Esc cancel"
    ShowingCommand(_), _ -> "Esc back"
    Browsing, ListingPrincipals ->
      "↑↓ select · Enter memberships · c revoke credentials · i invite · t rotate · r refresh"
      <> continuation(state.principals_next)
      <> " · Esc close"
    Browsing, ListingMemberships(_) ->
      "↑↓ select · o operator · b observer · d revoke · c revoke credentials · r refresh"
      <> continuation(state.memberships_next)
      <> " · Esc back"
  }
  let outcome = case state.outcome {
    Some(message) -> [quiet(text.truncate(message, width, "…"))]
    None -> []
  }
  let notice = case state.notice {
    "" -> []
    message -> [quiet(text.truncate(message, width, "…"))]
  }
  list.flatten([outcome, notice, [quiet(text.truncate(keys, width, "…"))]])
}

fn continuation(next: Option(String)) -> String {
  case next {
    Some(_) -> " · n more"
    None -> ""
  }
}

// Whole rows scroll under the cursor, after the heading lines that stay.
fn row_viewport(
  content: List(span.Line),
  selected: Int,
  row_height: Int,
  heading: Int,
  room: Int,
) -> List(span.Line) {
  let head = list.take(content, int.min(heading, room))
  let rows = list.drop(content, heading)
  let row_room = int.max(0, room - list.length(head))
  let rows_per_page = int.max(1, row_room / row_height)
  let first = selected / rows_per_page * rows_per_page
  let shown =
    rows
    |> list.drop(first * row_height)
    |> list.take(row_room)
  list.append(head, shown)
}

fn principal_lines(state: State, width: Int) {
  let heading = [
    plain("Principals · who can reach this daemon"),
    quiet("Enter shows a principal's sessions."),
  ]
  case state.principals {
    [] -> [plain("Principals"), quiet("No principal has been read yet.")]
    principals ->
      list.append(
        heading,
        list.flat_map(
          list.index_map(principals, fn(row, index) { #(row, index) }),
          fn(pair) {
            let #(principal, index) = pair
            principal_rows(principal, state.selected_principal, index, width)
          },
        ),
      )
  }
}

fn principal_rows(
  principal: Principal,
  selected_index: Int,
  row_index: Int,
  width: Int,
) {
  [
    row_line(
      marker(selected_index, row_index)
        <> principal.name
        <> " · "
        <> kind_label(principal.kind),
      width,
      selected_index,
      row_index,
    ),
    quiet(text.truncate(
      "    " <> credential_label(principal.credential),
      width,
      "…",
    )),
    quiet(text.truncate("    id " <> principal.id, width, "…")),
  ]
}

fn membership_lines(state: State, principal: Principal, width: Int) {
  let heading = [
    plain("Access of " <> principal.name),
    quiet(text.truncate("id " <> principal.id, width, "…")),
  ]
  case state.memberships {
    [] ->
      list.append(heading, [
        quiet(case principal.kind {
          Owner -> "The owner holds no memberships."
          Member -> "This principal holds no membership."
        }),
      ])
    memberships ->
      list.append(
        heading,
        list.flat_map(
          list.index_map(memberships, fn(row, index) { #(row, index) }),
          fn(pair) {
            let #(membership, index) = pair
            membership_rows(membership, state.selected_membership, index, width)
          },
        ),
      )
  }
}

fn membership_rows(
  membership: Membership,
  selected_index: Int,
  row_index: Int,
  width: Int,
) {
  [
    row_line(
      marker(selected_index, row_index)
        <> membership.name
        <> " · "
        <> role_label(membership.role),
      width,
      selected_index,
      row_index,
    ),
    quiet(text.truncate("    session " <> membership.session_id, width, "…")),
  ]
}

fn review_lines(change: Change, width: Int) {
  let question = case change {
    SetRole(principal_name:, session_name:, role:, ..) ->
      "Set "
      <> principal_name
      <> " to "
      <> role_label(role)
      <> " in "
      <> session_name
      <> "?"
    RevokeMembership(principal_name:, session_name:, ..) ->
      "Revoke " <> principal_name <> "'s access to " <> session_name <> "?"
    RevokeCredentials(principal_name:, ..) ->
      "Revoke every credential of " <> principal_name <> "?"
  }
  let consequence = case change {
    SetRole(..) -> "The role changes for this session only, at once."
    RevokeMembership(..) ->
      "The member loses this session only, at once. Other sessions are unchanged."
    RevokeCredentials(..) ->
      "The credential and any open claim stop working. Access returns only through a new invitation or rotation."
  }
  list.flatten([
    wrapped(question, width, plain),
    wrapped(identity_line(change), width, quiet),
    wrapped(consequence, width, quiet),
  ])
}

fn identity_line(change: Change) -> String {
  case change {
    SetRole(principal_id:, session_id:, ..)
    | RevokeMembership(principal_id:, session_id:, ..) ->
      "principal " <> principal_id <> " · session " <> session_id
    RevokeCredentials(principal_id:, ..) -> "principal " <> principal_id
  }
}

fn command_lines(line: String, width: Int) {
  list.flatten([
    [plain("Run this in a shell, not here:")],
    wrapped(line, width, plain),
    wrapped(
      "The command prints a claim. This terminal never shows one, so a recording of it cannot hold one. Send the claim outside Loom.",
      width,
      quiet,
    ),
  ])
}

fn wrapped(value: String, width: Int, line: fn(String) -> span.Line) {
  value
  |> text_hygiene.single_line
  |> text.wrap(int.max(1, width))
  |> list.map(line)
}

fn kind_label(kind: Kind) -> String {
  case kind {
    Owner -> "owner"
    Member -> "member"
  }
}

fn role_label(role: MemberRole) -> String {
  case role {
    OperatorRole -> "operator"
    ObserverRole -> "observer"
  }
}

fn credential_label(credential: Credential) -> String {
  case credential {
    Active(fingerprint:, claimed_at_ms: Some(_)) ->
      "credential active · fingerprint " <> fingerprint <> " · bound by a claim"
    Active(fingerprint:, claimed_at_ms: None) ->
      "credential active · fingerprint "
      <> fingerprint
      <> " · enrolled by digest"
    ClaimOpen(expires_in_ms:) ->
      "claim open · expires in " <> duration_label(expires_in_ms)
    ClaimExpired -> "claim expired unredeemed · no credential"
    NoCredential -> "no credential"
  }
}

// A remaining lifetime as one unit, rounded up so a claim with seconds left
// is never shown as already gone.
fn duration_label(ms: Int) -> String {
  let minutes = { ms + 59_999 } / 60_000
  case minutes {
    _ if minutes >= 2880 -> int.to_string({ minutes + 1439 } / 1440) <> " days"
    _ if minutes >= 120 -> int.to_string({ minutes + 59 } / 60) <> " hours"
    1 -> "1 minute"
    _ -> int.to_string(int.max(minutes, 0)) <> " minutes"
  }
}

// The selection mark carries the highlight without color.
fn marker(selected_index: Int, row_index: Int) -> String {
  case selected_index == row_index {
    True -> "› "
    False -> "  "
  }
}

fn row_line(value: String, width: Int, selected_index: Int, row_index: Int) {
  let value =
    value
    |> text_hygiene.single_line
    |> text.truncate(width, "…")
    |> text.pad_right(width)
  let row_style = case selected_index == row_index {
    True -> style.new(theme.signal, theme.raised, style.bold())
    False -> theme.overlay_quiet()
  }
  span.line_new([span.span_styled(value, row_style)])
}

fn plain(value: String) {
  span.line_new([
    span.span_styled(text_hygiene.single_line(value), theme.overlay_plain()),
  ])
}

fn quiet(value: String) {
  span.line_new([
    span.span_styled(text_hygiene.single_line(value), theme.overlay_quiet()),
  ])
}

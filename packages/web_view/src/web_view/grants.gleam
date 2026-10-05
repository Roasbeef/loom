//// What the owner's admin page reads and asks (protocol-change/065, the fifth
//// pull request): the principals and one session's members as the catalogue
//// lists them, the five things the page may change, and the fixed words for
//// every answer.
////
//// The admin page changes who may see the owner's sessions, and a page never
//// holds owner authority. It asks the daemon to make the same changes `loomd
//// access` makes, through the same registry dispatch, and the daemon decides
//// whether the page's principal may ask. This module holds the types the
//// reads and the asks are made of, so the page and the daemon agree on a
//// vocabulary without the page learning anything else about the daemon's
//// administration.
////
//// Every field a read carries is the catalogue's: a principal's identity and
//// display name, a credential's fingerprint and lifetime, a member's role. A
//// credential appears only as the first sixteen characters of its digest and
//// a claim only as the time it has left, which is all the registry's listing
//// holds (`storage/access.CredentialSummary`). A claim token exists in an
//// answer to one ask and nowhere else (`Claim`): the page shows it once and
//// drops it when the owner dismisses it.
////
//// The two grants an ask can make, an invitation and a rotation, return a
//// claim. A role raised to operator is a grant too, and it returns none; the
//// daemon counts all three against one allowance per credential, the one the
//// session page's invitation control is held to
//// (`client/daemon/ui_sessions.invite_limit`). Every change that only reduces
//// access costs nothing.

import gleam/int
import gleam/option.{type Option}
import gleam/string
import web_view/creations.{type Sharing}
import web_view/ending.{type Ending}
import web_view/invites.{type Role}
import web_view/sessions.{type Entry}
import web_view/signins.{type Signin}

/// Whether a principal is the daemon's owner. The page offers the owner no
/// action, since the owner's access is not the page's to change.
pub type Kind {
  /// The one principal whose credential administers the daemon.
  OwnerKind

  /// An invited person.
  MemberKind
}

/// What a principal can authenticate with, or come to, as the owner's listing
/// reports it (`storage/access.CredentialSummary`).
pub type Credential {
  /// One active credential. `fingerprint` is the first sixteen characters of
  /// its digest, which is enough to compare with what `loom claim` printed and
  /// no use for signing in. `claimed_at_ms` is the wall-clock instant a claim
  /// bound it, and is absent for the owner's credential and for one enrolled
  /// by digest.
  Active(fingerprint: String, claimed_at_ms: Option(Int))

  /// An open claim that has not expired: a pending invitation, with the time
  /// it has left in milliseconds.
  ClaimOpen(expires_in_ms: Int)

  /// A member whose only claim expired unredeemed and who holds no active
  /// credential. A rotation issues a new claim.
  ClaimExpired

  /// No active credential and no open claim: revoked, or never enrolled.
  NoCredential
}

/// One principal and the credential state the owner's listing shows for it.
pub type Principal {
  Principal(
    /// The principal's recovery identity: the daemon's `guest-` and eight
    /// hexadecimal digits for an invitation made from a page, or what the
    /// owner chose in a terminal. It is a catalogue field and is drawn as text.
    id: String,
    /// The display name, which the owner or the invitee chose. Peer text:
    /// it is only ever a text node.
    name: String,
    /// Whether this is the owner.
    kind: Kind,
    /// What the principal can authenticate with.
    credential: Credential,
  )
}

/// One member of a session: the principal and the role it holds there.
pub type Holder {
  Holder(
    /// The member's recovery identity.
    principal: String,
    /// The member's display name, peer text.
    name: String,
    /// The role the member holds in this session.
    role: Role,
  )
}

/// Whether a list is all of what the catalogue holds. A page holds at most one
/// listing page of each, and says so when there is more.
pub type More {
  /// Every row is here.
  Whole

  /// More rows exist than a page lists. The terminal's `loom access` pages
  /// through them.
  Truncated
}

/// One session's members, as the last read found them.
pub type Selection {
  Selection(
    /// The session's canonical identity.
    session: String,
    /// Its members in principal order. The owner holds no membership rows, so
    /// it never appears here.
    holders: List(Holder),
    /// Whether these are all of them.
    more: More,
    /// Whether the session may be shared. The registry holds the scope the
    /// session was created with, which `sessions.members` reports
    /// (protocol-change/065, the addendum on `scope`). A private session shares
    /// its notes and history with its workspace, so the page draws no
    /// invitation form for it.
    scope: Sharing,
  )
}

/// One principal's browser logins, as the last read found them
/// (protocol-change/065, the eighth pull request): how many are active and
/// unexpired, and the first of them. The fingerprints identify a login and
/// authenticate nothing.
pub type Logins {
  Logins(
    /// The principal these belong to, one of the snapshot's principals.
    principal: String,
    /// How many logins the principal holds that are active and have not reached
    /// their expiry, whether or not they are listed here.
    count: Int,
    /// The first of them, at most `signins_shown`, in the daemon's order.
    shown: List(Signin),
  )
}

/// The most sign-ins the admin page lists for one principal. A principal with
/// more says so and leaves the rest to `loom access signins`.
pub const signins_shown = 10

/// What one read of the catalogue gave: who exists, which sessions the owner
/// holds, and, when the page has chosen one, that session's members.
pub type Snapshot {
  Snapshot(
    /// The principals, the owner and the invited, in identity order.
    principals: List(Principal),
    /// Whether `principals` is all of them.
    more_principals: More,
    /// The owner's sessions in the catalogue's order, for choosing one.
    sessions: List(Entry),
    /// The chosen session's members, or `None` when no session is chosen or
    /// the catalogue holds no such session.
    selection: Option(Selection),
    /// The sign-ins of each principal that holds any, in the principals' order.
    logins: List(Logins),
  )
}

/// What a read answers.
pub type Reading {
  /// The catalogue's answer.
  Read(snapshot: Snapshot)

  /// The registry did not answer. The page keeps what it has and draws nothing
  /// about it, since a slow registry is no reason to say anything.
  Unread

  /// The page can no longer be served, and why: its UI session ended or its
  /// credential no longer authenticates as the owner. The page draws the
  /// ending and asks for nothing more.
  Closed(ending: Ending)
}

/// The six changes the page may ask for. Every identity in one is the
/// catalogue's, drawn into the tree by the server, and the text of a name is
/// the browser's and nothing else is: a frame cannot name a session or a
/// principal the page did not draw. The daemon checks each again, from the
/// credential the page was admitted under, when the request runs.
pub type Action {
  /// Invite a new principal into a session with a role. `name` is the
  /// inviter's suggestion, which the invitee may replace at the claim; blank
  /// leaves the daemon's own. A grant: it costs one of the credential's
  /// allowance.
  Invite(session: String, role: Role, name: String)

  /// Change one member's role in one session. Raising it to operator is a
  /// grant and costs one allowance; lowering it costs none.
  SetRole(session: String, principal: String, role: Role)

  /// Remove one member from one session without touching its other
  /// memberships. A reduction, which costs nothing.
  RevokeMembership(session: String, principal: String)

  /// Revoke every credential of a principal and void its open claim, keeping
  /// the identity. A reduction, which costs nothing.
  RevokeCredentials(principal: String)

  /// Void a principal's credentials and claim and issue a new claim. A grant:
  /// it costs one allowance.
  Rotate(principal: String)

  /// End one browser login of a principal, named by its fingerprint, which the
  /// server drew into the tree beside it. Every page the login minted ends at
  /// its next request. A reduction, which costs nothing.
  RevokeSignin(principal: String, fingerprint: String)
}

/// What a claim was made for, which the page words.
pub type Purpose {
  /// A new principal was invited into a session with this role.
  Invited(role: Role)

  /// An existing principal's credentials were replaced.
  Rotated
}

/// A claim the daemon made, which the owner shows to one person once.
pub type Claim {
  Claim(
    /// The principal the claim binds a credential to.
    principal: String,
    /// What the claim was made for.
    purpose: Purpose,
    /// The address a person without `loom` opens to claim in a browser:
    /// `http://`, the host the page was reached at and `/ui/claim`
    /// (`web_view/page.claim_path`). It names no token.
    page: String,
    /// The command the person runs, `loom claim --addr ...`. It names the
    /// address and never the token.
    command: String,
    /// The claim token, `loomclaim_` and 64 hexadecimal digits. It is shown
    /// once and the page drops it when the owner dismisses it.
    token: String,
    /// How long the claim stays valid, in milliseconds from the moment it was
    /// made. A duration, so the page needs no clock agreement.
    expires_in_ms: Int,
  )
}

/// The daemon's answer to an ask.
pub type Answer {
  /// An invitation or a rotation made a claim, which the page shows once.
  Claimed(claim: Claim)

  /// The change was made, and made no claim.
  Changed

  /// The daemon changed nothing. Every page shows the fixed words for the
  /// reason (`reason_words`), never the daemon's own text.
  Declined(reason: Reason)
}

/// Why the daemon changed nothing.
pub type Reason {
  /// The page's principal is not the daemon's owner, the page was not minted to
  /// operate, or the page has ended. One answer for all, so a page learns
  /// nothing else about its standing.
  NotOwner

  /// This credential has granted as often as it may recently. The count is the
  /// daemon's and is kept for the credential and not for the page, so opening
  /// another page does not reset it, and it is shared with the invitation
  /// control on a session's page. `used` is how many places the window holds,
  /// which is the whole allowance, and `free_at_ms` is the Unix time in
  /// milliseconds at which the oldest of them leaves the window, so the next
  /// grant is possible then.
  TooMany(used: Int, free_at_ms: Int)

  /// The session still shares its history with its workspace, so the daemon
  /// refuses to give another person a seat in it until it is isolated.
  NotIsolated

  /// The session or the principal is not one the catalogue holds now: the page
  /// drew a row that was removed since.
  NotFound

  /// The suggested name is empty after trimming, longer than 256 bytes, or holds
  /// a control, zero-width or direction-changing character.
  InvalidName

  /// The daemon could not answer: it was starting, stopping or slow, or the
  /// change could not be recorded.
  Unavailable
}

/// The words a page shows for a refused ask. They are fixed here, one per
/// reason, so nothing the daemon or a peer wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert grants.reason_words(grants.NotOwner)
///   == "Only the owner can administer from a page."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotOwner -> "Only the owner can administer from a page."
    TooMany(used:, free_at_ms:) ->
      int.to_string(used)
      <> " grants in the last hour is the most a credential may make. The next is free at "
      <> clock_words(free_at_ms)
      <> ". Until then, use loomd access from a terminal."
    NotIsolated -> invites.reason_words(invites.NotIsolated)
    NotFound -> "That session or person is no longer there. The page reloads."
    InvalidName ->
      "Use a name of up to 256 bytes with no control or invisible characters."
    Unavailable -> "The daemon could not make that change. Try again."
  }
}

// A Unix time in milliseconds as the UTC time of day to the minute, `HH:MM UTC`.
// The page cannot know the owner's zone, so it names the one it counts in.
fn clock_words(milliseconds: Int) -> String {
  let minutes = int.max(milliseconds, 0) / 60_000 % 1440
  pad(minutes / 60) <> ":" <> pad(minutes % 60) <> " UTC"
}

fn pad(number: Int) -> String {
  case number < 10 {
    True -> "0" <> int.to_string(number)
    False -> int.to_string(number)
  }
}

/// A principal's identity as the page draws it: the prefix before its first
/// hyphen and the first eight characters after it, so
/// `owner-2056528fe1be0db0f7105a24da3aac4dcf722898c6655129c0eabc6231181a05`
/// reads `owner-2056528f`. An identity that is already that short, as a
/// `guest-` one is, is unchanged. The whole identity goes in the element's
/// `title`.
///
/// ## Examples
///
/// ```gleam
/// assert grants.short_identity("guest-956fb176") == "guest-956fb176"
/// assert grants.short_identity("owner-2056528fe1be0db0f7105a24da3aac4d")
///   == "owner-2056528f"
/// ```
pub fn short_identity(identity: String) -> String {
  case string.split_once(identity, "-") {
    Ok(#(prefix, rest)) ->
      case string.length(rest) > 8 {
        True -> prefix <> "-" <> string.slice(rest, 0, 8)
        False -> identity
      }
    Error(Nil) -> string.slice(identity, 0, 8)
  }
}

/// The words a page shows for a change that was made. A claim has its own
/// display, so these are for `Changed`.
///
/// ## Examples
///
/// ```gleam
/// assert grants.changed_words(grants.SetRole("s", "p", invites.Observer))
///   == "Role changed."
/// ```
pub fn changed_words(action: Action) -> String {
  case action {
    SetRole(..) -> "Role changed."
    RevokeMembership(..) -> "Membership removed."
    RevokeCredentials(..) -> "Credentials revoked."
    RevokeSignin(..) -> "Sign-in ended."
    Invite(..) | Rotate(..) -> "Done."
  }
}

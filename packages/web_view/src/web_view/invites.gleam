//// The one invitation an owner's page may mint: what the page asks, what the
//// daemon answers, and the fixed words for each refusal
//// (protocol-change/051, the addendum on inviting from the session page).
////
//// Inviting a person to a session is an owner's control action, and a page
//// never holds owner authority (`ui_relay.capped`). The page therefore has
//// no invitation of its own to make. It asks the daemon to make the same
//// invitation `loomd access invite` makes, through the same manager
//// dispatch, for this page's session only and with nothing else to choose:
//// the two roles below, and no name, no principal, no session and no
//// lifetime. The daemon decides whether the page's principal may ask, and
//// this module holds the types the answer is made of, so the page and the
//// daemon agree on the vocabulary without the page learning anything else
//// about the daemon's administration.
////
//// The claim token an answer carries is a secret that exists in three places
//// and no more: the daemon's reply frame, the component's state while the
//// invitation is on screen (`Share`'s `Showing`), and the browser's copy of
//// the page. Nothing here writes it anywhere durable, and the state that
//// holds it is replaced when the owner dismisses it.

/// The role an owner may give an invitee from a page. `Owner` is not a value
/// of this type, so a page cannot ask for one whatever a browser sends.
pub type Role {
  /// The invitee may follow the session and send nothing. This is what the
  /// page offers first.
  Observer

  /// The invitee may send prompts and answer approvals. It is a second
  /// button, named for what it allows.
  Operator
}

/// What the daemon minted: one invited principal, and the single-use claim
/// that binds a credential to it.
pub type Invitation {
  Invitation(
    /// The invited principal's recovery ID, which the daemon chose
    /// (`guest-` and eight hexadecimal digits). The owner needs it to revoke
    /// the invitation from a terminal.
    principal: String,
    /// The role the invitee will hold in this session.
    role: Role,
    /// The command the invitee runs, `loom claim --addr ...`. It names the
    /// address and never the token.
    command: String,
    /// The claim token, `loomclaim_` and 64 hexadecimal digits. It is shown
    /// once and never leaves the page's state except through the owner's
    /// own copy.
    token: String,
    /// How long the claim stays valid, in milliseconds from the moment it was
    /// minted. A duration, so the page needs no clock agreement.
    expires_in_ms: Int,
  )
}

/// Why the daemon minted nothing. Every page shows the fixed words for the
/// reason (`reason_words`), never the daemon's own text.
pub type Reason {
  /// The page's principal is not the daemon's owner, or the page has ended.
  /// One answer for both, so a page learns nothing else about its standing.
  NotOwner

  /// This credential has invited as often as it may recently. The count is
  /// the daemon's and is kept for the credential and not for the page, so
  /// opening another page does not reset it.
  TooMany

  /// The session still shares its history with its workspace, so the daemon
  /// refuses to give another person a seat in it until it is isolated.
  NotIsolated

  /// The daemon could not answer: it was starting, stopping or slow, or the
  /// invitation could not be recorded.
  Unavailable
}

/// The daemon's answer to a request to invite.
pub type Answer {
  /// The daemon minted an invitation. It is shown to the owner once.
  Minted(invitation: Invitation)

  /// The daemon minted nothing.
  Declined(reason: Reason)
}

/// What the page's invitation control is doing. It is a page's own state and
/// nothing the session records.
pub type Share {
  /// The page's principal cannot invite, and the page draws no control. An
  /// observer's page is always here, and so is an operator's whose principal
  /// is a member.
  Withheld

  /// The control is drawn and waits for the owner to press a button.
  Ready

  /// A request is with the daemon. A press meanwhile is ignored, so one press
  /// mints at most one invitation.
  Asking

  /// The invitation is on screen, with its token. It stays until the owner
  /// dismisses it, and is the only place the page keeps the token.
  Showing(invitation: Invitation)

  /// The daemon minted nothing, and the control says why in the reason's
  /// fixed words.
  Refused(reason: Reason)
}

/// How long an invitation's claim lives, in milliseconds: one hour.
///
/// The control has no lifetime to choose. An hour is long enough to paste the
/// command and the token into a message and for the person to read it
/// between two other things. It is short enough that a token left in a chat
/// window, a clipboard history or a scrollback is dead before the day is
/// out, where 053's default of a day would leave it working until tomorrow.
/// An owner whose invitee did not get to it in an hour presses the button
/// again, which voids nothing and costs one more of the credential's few
/// invitations (`client/daemon/ui_sessions.invite_limit`).
pub const claim_ttl_ms = 3_600_000

/// The word for a role, as the page and the invitation's summary say it.
///
/// ## Examples
///
/// ```gleam
/// assert invites.role_word(invites.Observer) == "observer"
/// ```
pub fn role_word(role: Role) -> String {
  case role {
    Observer -> "observer"
    Operator -> "operator"
  }
}

/// The words a page shows for a declined invitation. They are fixed here, one
/// per reason, so nothing the daemon or a session wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert invites.reason_words(invites.NotOwner)
///   == "Only the owner can invite from a page."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotOwner -> "Only the owner can invite from a page."
    TooMany ->
      "This credential has invited several people recently. Wait, or use loomd access invite from a terminal."
    NotIsolated ->
      "This session is not shared yet. Stop it, isolate its transcript from a terminal with loomd access isolate, and resume it."
    Unavailable -> "The daemon could not create the invitation. Try again."
  }
}

/// The lifetime the invitation shows, in whole minutes, rounded down, as the
/// summary line words it.
///
/// ## Examples
///
/// ```gleam
/// assert invites.minutes(3_600_000) == 60
/// ```
pub fn minutes(expires_in_ms: Int) -> Int {
  expires_in_ms / 60_000
}

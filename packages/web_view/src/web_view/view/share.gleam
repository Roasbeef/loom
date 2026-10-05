//// The Session tab's invitation control, drawn on an owner's page only
//// (protocol-change/051, the addendum on inviting from the session page).
////
//// The control has one action, "invite to this session", offered as two
//// buttons, one per role an owner may give: observer first, and operator
//// second. Neither takes a field, so the browser has nothing to send but the
//// press, and the press names its role in the message the server drew.
//// Nothing else about the invitation is chosen here or on the page: not the
//// principal, the session, the lifetime or the name.
////
//// After the daemon has minted an invitation the control shows it once, in
//// place of the buttons: the address an invitee without `loom` opens to claim
//// in a browser, the claim token, and, second, the command an invitee with
//// `loom` runs (`handover`, which the admin page's claim box shares). Each is
//// in a `<loom-copy>` box (`packages/web_client`), and the words say what the
//// owner needs to hand them over safely. The text travels as the box's `text`
//// attribute, which the element draws and copies only when it has the exact
//// shape the daemon writes for its subject. The words are fixed text. They say
//// that both travel outside Loom, because a token pasted into a session
//// becomes transcript the agent reads and can redeem before the invitee does
//// (protocol-change/053), and that the owner confirms the fingerprint `loom
//// claim` prints with the invitee afterwards, since the page cannot see a
//// credential that has not been bound yet.
////
//// The region is the Session pane's last child, so its handlers are beneath
//// `component.invite_path` whichever state it is in, and the page socket
//// admits a click there only for an owner. A page whose principal cannot
//// invite draws `element.none()` in the same place, so no other path moves.
//// The module takes the three messages it sends as values, because
//// `web_view/operator_page` owns the message type and imports this module.
////
//// Nothing here is session text. The words are fixed here, and the principal,
//// the command and the token are the daemon's own. The words and the
//// principal are text nodes. The command and the token are attribute values
//// on a client element that checks their shape, and none is ever a class, a
//// key, a URL or a handler's message.

import gleam/int
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/invites.{type Invitation, type Share}

/// The messages the control's buttons send.
pub type Presses(message) {
  Presses(
    /// The "Invite an observer" button.
    observer: message,
    /// The "Invite an operator" button.
    operator: message,
    /// The button that hides an invitation once the owner has copied it.
    done: message,
  )
}

/// The control for the page's `share` state: nothing for a page that cannot
/// invite, the buttons while the control is ready or asking or refused, and
/// the invitation while it is showing.
///
/// ## Examples
///
/// ```gleam
/// // share.view(invites.Ready, share.Presses(Inviting(Observer), Inviting(Operator), Dismissed))
/// ```
pub fn view(share: Share, presses: Presses(message)) -> Element(message) {
  case share {
    invites.Withheld -> element.none()
    invites.Unshareable -> private()
    invites.Showing(invitation:) -> showing(invitation, presses)
    invites.Ready | invites.Asking | invites.Refused(..) ->
      buttons(presses, share)
  }
}

/// The sentence that stands where the buttons would, for a session that cannot
/// be shared. The admin page says the same words for the same session.
pub const private_words =
  "Private session: it shares the workspace's notes and history, so it cannot be shared. Sessions created with Shareable can be."

// The control for a private session: its heading and the sentence, with no
// button and no handler, in the region's place so no path moves.
fn private() -> Element(message) {
  html.section(
    [attribute.class("share"), attribute.aria_label("Invite to this session")],
    [
      html.h3([attribute.class("share-title")], [
        html.text("Invite to this session"),
      ]),
      html.p([attribute.class("share-lead")], [html.text(private_words)]),
    ],
  )
}

// The two buttons and a status line. The line is always drawn, empty unless
// a request was refused, so the region's children keep their places. While a
// request is with the daemon the buttons are disabled and carry no handler.
fn buttons(presses: Presses(message), share: Share) -> Element(message) {
  html.section(
    [attribute.class("share"), attribute.aria_label("Invite to this session")],
    [
      html.h3([attribute.class("share-title")], [
        html.text("Invite to this session"),
      ]),
      html.p([attribute.class("share-lead")], [
        html.text(
          "Creates a single-use claim token that expires in "
          <> int.to_string(invites.minutes(invites.claim_ttl_ms))
          <> " minutes.",
        ),
      ]),
      html.div([attribute.class("share-actions")], [
        button(
          "share-observe",
          "Invite an observer",
          "Can follow this session and send nothing.",
          share,
          presses.observer,
        ),
        button(
          "share-operate",
          "Invite an operator",
          "Can send prompts and answer approval requests.",
          share,
          presses.operator,
        ),
      ]),
      status(share),
    ],
  )
}

fn button(
  class: String,
  label: String,
  title: String,
  share: Share,
  message: message,
) -> Element(message) {
  let common = [
    attribute.type_("button"),
    attribute.class(class),
    attribute.title(title),
  ]
  case share {
    invites.Asking ->
      html.button([attribute.disabled(True), ..common], [html.text(label)])
    invites.Withheld
    | invites.Unshareable
    | invites.Ready
    | invites.Showing(..)
    | invites.Refused(..) ->
      html.button([event.on_click(message), ..common], [html.text(label)])
  }
}

// The refusal in the reason's fixed words, or the empty line.
fn status(share: Share) -> Element(message) {
  case share {
    invites.Refused(reason:) ->
      html.p([attribute.class("share-status"), attribute.role("status")], [
        html.text(invites.reason_words(reason)),
      ])
    invites.Withheld
    | invites.Unshareable
    | invites.Ready
    | invites.Asking
    | invites.Showing(..) ->
      html.p([attribute.class("share-status"), attribute.role("status")], [])
  }
}

// The invitation, once. Both secrets are in copy boxes and nowhere else, and
// the button that ends the display is the last thing in the region.
fn showing(
  invitation: Invitation,
  presses: Presses(message),
) -> Element(message) {
  html.section(
    [
      attribute.class("share"),
      attribute.class("share-shown"),
      attribute.aria_label("Invitation"),
    ],
    list.flatten([
      [
        html.h3([attribute.class("share-title")], [
          html.text("Invitation ready"),
        ]),
        html.p([attribute.class("share-lead")], [
          html.text(
            "Role: "
            <> invites.role_word(invitation.role)
            <> ". Principal: "
            <> invitation.principal
            <> ". Single use, valid for "
            <> int.to_string(invites.minutes(invitation.expires_in_ms))
            <> " minutes.",
          ),
        ]),
        html.p([attribute.class("share-lead")], [
          html.text(
            "Send the command and the token to the person over a channel outside Loom, never through this session: text sent here becomes transcript, and the agent can read it and use the token first.",
          ),
        ]),
      ],
      handover(
        invitation.page,
        invitation.command,
        invitation.token,
        "loom claim prints a credential fingerprint; compare it with them before you rely on the new member. If the token is not used, void it with loomd access revoke-credentials "
          <> invitation.principal
          <> ".",
      ),
      [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("share-done"),
            event.on_click(presses.done),
          ],
          [html.text("Hide the token")],
        ),
      ],
    ]),
  )
}

/// What the owner hands to the person an invitation or a rotation is for, in
/// the order they use it: the browser claim address, the token, and, as the
/// second way, the `loom claim` command for a person who has `loom`. A person
/// without `loom` can only use the first, which is who an invitation made from a
/// browser is usually for, so it leads (protocol-change/065, the addendum on the
/// browser claim). `after_claim` is the fixed sentence that says what the owner
/// checks once the command has run, since the fingerprint `loom claim` prints
/// applies to it alone.
///
/// The words are fixed here. The three values are the daemon's own and travel
/// only as the `text` of a copy box.
///
/// ## Examples
///
/// ```gleam
/// // share.handover(claim.page, claim.command, claim.token, "loom claim prints a key.")
/// ```
pub fn handover(
  page: String,
  command: String,
  token: String,
  after_claim: String,
) -> List(Element(message)) {
  [
    html.p([attribute.class("share-lead")], [
      html.text("Open this address and paste the token:"),
    ]),
    field("Claim address", "claim-address", page),
    field("Claim token", "token", token),
    html.p([attribute.class("share-lead")], [
      html.text(
        "This box is the only place the token is shown, so copy it now.",
      ),
    ]),
    html.p([attribute.class("share-lead")], [
      html.text(
        "Or, with loom installed, run this on the machine that runs the daemon:",
      ),
    ]),
    field("Command", "command", command),
    html.p([attribute.class("share-lead")], [html.text(after_claim)]),
  ]
}

/// One labelled copy box. `subject` is one of two fixed words, and `text` is
/// the daemon's own value; `<loom-copy>` (`packages/web_client`) draws the text
/// itself as a text node in its shadow root and copies it when the button is
/// pressed, and only if it has the shape the subject allows. The box carries
/// no child and no handler on the server's side. The admin page shows a claim
/// it made in the same boxes (`view/admin_claim`).
///
/// ## Examples
///
/// ```gleam
/// // share.field("Command", "command", invitation.command)
/// ```
pub fn field(label: String, subject: String, text: String) -> Element(message) {
  html.div([attribute.class("share-field")], [
    html.span([attribute.class("share-label")], [html.text(label)]),
    element.element(
      "loom-copy",
      [
        attribute.attribute("subject", subject),
        attribute.attribute("text", text),
      ],
      [],
    ),
  ])
}

//// The claim the admin page has just made, shown to the owner once.
////
//// An invitation or a rotation ends in a claim: a single-use token that binds
//// a credential to a principal. The daemon returns it to the page that asked
//// and keeps only its digest, so this display is the one place the token ever
//// exists on screen and the only frame of the admin socket that carries one.
//// It stays in the component's state until the owner presses the button that
//// hides it, which replaces it with the empty slot it occupies, and nothing
//// else ever draws it: not a refresh, not a listing, not a later action.
////
//// The command and the token are each in a `<loom-copy>` box
//// (`packages/web_client`), which draws and copies a value only when it has
//// the exact shape the daemon writes, and the fixed words say what the owner
//// must do with them: send both outside Loom, never through a session, because
//// text pasted into a session becomes transcript the agent can read and use
//// first (protocol-change/053), and compare the fingerprint `loom claim`
//// prints with the person afterwards. The principal's identity is the
//// daemon's and is a text node.
////
//// The region is always one child of the page's body: this display while a
//// claim is on screen and `element.none()` otherwise, so the children after it
//// keep their paths.

import gleam/int
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/grants.{type Claim}
import web_view/invites
import web_view/view/share

/// The display for the claim on screen, or the empty slot. `dismiss` is the
/// message the button that hides it sends.
///
/// ## Examples
///
/// ```gleam
/// // admin_claim.view(Some(claim), Dismissed)
/// // admin_claim.view(None, Dismissed)
/// ```
pub fn view(claim: Option(Claim), dismiss: message) -> Element(message) {
  case claim {
    None -> element.none()
    Some(claim) -> shown(claim, dismiss)
  }
}

// The display itself: what the claim is for, both secrets in copy boxes, the
// words the owner needs to hand both over safely, and the button that ends it.
fn shown(claim: Claim, dismiss: message) -> Element(message) {
  html.section(
    [
      attribute.class("share"),
      attribute.class("share-shown"),
      attribute.aria_label("Claim"),
    ],
    [
      html.h3([attribute.class("share-title")], [html.text(title(claim))]),
      html.p([attribute.class("share-lead")], [
        html.text(
          purpose(claim)
          <> " Single use, valid for "
          <> int.to_string(invites.minutes(claim.expires_in_ms))
          <> " minutes.",
        ),
      ]),
      html.p([attribute.class("share-lead")], [
        html.text(
          "Send the command and the token to the person over a channel outside Loom, never through a session: text sent there becomes transcript, and the agent can read it and use the token first.",
        ),
      ]),
      share.field("Command", "command", claim.command),
      share.field("Claim token", "token", claim.token),
      html.p([attribute.class("share-lead")], [
        html.text(
          "The command works on the machine that runs this daemon. This box is the only place the token is shown, so copy it now.",
        ),
      ]),
      html.p([attribute.class("share-lead")], [
        html.text(
          "After they have run it, ask them for the credential fingerprint that loom claim prints, and compare it with the one listed for them here before you rely on them.",
        ),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("share-done"),
          event.on_click(dismiss),
        ],
        [html.text("Hide the token")],
      ),
    ],
  )
}

// The display's title, by what the claim is for.
fn title(claim: Claim) -> String {
  case claim.purpose {
    grants.Invited(..) -> "Invitation ready"
    grants.Rotated -> "New claim ready"
  }
}

// The sentence that says who the claim is for and why, with the principal's
// identity as text.
fn purpose(claim: Claim) -> String {
  case claim.purpose {
    grants.Invited(role:) ->
      "Role: "
      <> invites.role_word(role)
      <> ". Principal: "
      <> claim.principal
      <> "."
    grants.Rotated ->
      "Principal: "
      <> claim.principal
      <> ". Their earlier credentials no longer work."
  }
}

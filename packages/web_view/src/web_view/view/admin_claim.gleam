//// The claim the admin page has just made, shown to the owner once, in the
//// place of the action that made it.
////
//// An invitation or a rotation ends in a claim: a single-use token that binds
//// a credential to a principal. The daemon returns it to the page that asked
//// and keeps only its digest, so this display is the one place the token ever
//// exists on screen and the only frame of the admin socket that carries one.
//// It stays in the component's state until the owner presses the button that
//// hides it, which replaces it with the empty slot it occupies, and nothing
//// else ever draws it: not a refresh, not a listing, not a later action.
////
//// The box is drawn beside what the owner pressed (round 4, F82). An
//// invitation's claim is under the invitation form, in the Sessions section
//// (`for_session`); a rotation's is under the person's row (`for_person`). It
//// is not sticky and it covers nothing: the page scrolls past it like any
//// other section. Each place is one child of its parent that is
//// `element.none()` while no claim belongs there, so a claim appearing, or the
//// children around it changing, never moves another child's path, and the
//// differ never has a reason to resend the token. The People list is keyed by
//// the principal's identity (`view/admin_people`), so a row inserted ahead of the
//// rotated person moves that row with its box, and the patch for a move carries
//// no content.
////
//// The box leads with the browser claim address, which a person without `loom`
//// must use, then the token with its copy button, then the `loom claim`
//// command as the second way (`view/share.handover`). Each is in a
//// `<loom-copy>` box (`packages/web_client`), which draws and copies a value
//// only when it has the exact shape the daemon writes. The fixed words say what
//// the owner must do with them: send them outside Loom, never through a
//// session, because text pasted into a session becomes transcript the agent can
//// read and use first (protocol-change/053), and compare the key `loom claim`
//// prints with the one listed under People. The principal's identity is the
//// daemon's and is a text node.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/grants.{type Claim}
import web_view/invites
import web_view/view/share

/// The slot under the invitation form: the display when the claim on screen is
/// an invitation's, and the empty node otherwise. `dismiss` is the message the
/// button that hides it sends.
///
/// ## Examples
///
/// ```gleam
/// // admin_claim.for_session(Some(claim), Dismissed)
/// // admin_claim.for_session(None, Dismissed)
/// ```
pub fn for_session(claim: Option(Claim), dismiss: message) -> Element(message) {
  case claim {
    Some(grants.Claim(purpose: grants.Invited(..), ..) as claim) ->
      shown(claim, dismiss)
    Some(grants.Claim(purpose: grants.Rotated, ..)) | None -> element.none()
  }
}

/// The slot in the row of `principal`: the display when the claim on screen is
/// a rotation of that principal's credentials, and the empty node otherwise.
///
/// ## Examples
///
/// ```gleam
/// // admin_claim.for_person(Some(claim), "guest-1a2b3c4d", Dismissed)
/// ```
pub fn for_person(
  claim: Option(Claim),
  principal: String,
  dismiss: message,
) -> Element(message) {
  case claim {
    Some(grants.Claim(purpose: grants.Rotated, principal: rotated, ..) as claim)
      if rotated == principal
    -> shown(claim, dismiss)
    Some(_) | None -> element.none()
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
    list.flatten([
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
            "Send the address and the token to the person over a channel outside Loom, never through a session: text sent there becomes transcript, and the agent can read it and use the token first.",
          ),
        ]),
      ],
      share.handover(
        claim.page,
        claim.command,
        claim.token,
        "loom claim prints a key; it should match the one listed under People.",
      ),
      [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("share-done"),
            event.on_click(dismiss),
          ],
          [html.text("Hide the token")],
        ),
      ],
    ]),
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

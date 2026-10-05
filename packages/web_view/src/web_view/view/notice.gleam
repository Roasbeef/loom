//// What a page says about the last thing its person did: one line, drawn beside
//// the part of the page that was acted on.
////
//// The session page's footer already tells the two kinds of outcome apart. A
//// change that was made is said once and fades, because the person watched it
//// happen and only needs it confirmed. A change that was refused stays, because
//// the person has not got what they asked for and must read why. The home and
//// the admin page used to draw both as one raised box at the top of the page,
//// which was far from the button that was pressed and never went away
//// (round 4, F78). This module draws them where the footer does: a quiet line
//// for `Said`, and a line in the danger colour with a tinted hairline for
//// `Refused`, each placed by its caller beside the control or heading the
//// action belongs to.
////
//// The fade is the stylesheet's (`loom-fade`, four seconds, which the footer's
//// notice also uses). The line stays in the tree after it has faded and goes
//// when the next action clears it, so the server keeps no timer for it.
////
//// A notice's words are fixed by the page (`web_view/grants.changed_words` and
//// `reason_words`), so they are never a peer's, and they are a text node. The
//// one instant a notice names, when a spent allowance frees a place, is a number
//// the daemon wrote in a `<loom-time>`, so the browser words it in its own zone. The
//// classes are complete literals. A notice draws no handler.
////
//// ## Placement
////
//// The admin page keeps the action with the words (`Spoken`), because where the
//// line goes depends on what was done. `at_person` draws it in the row of the
//// principal a person-level change names, `at_members` under the members'
//// heading for a change to one member, and `at_invitation` beside the
//// invitation form. Each answers `element.none()` when the notice belongs
//// elsewhere, so the slot it occupies is always one child of its parent and
//// the children after it keep their paths.

import gleam/int
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/grants.{type Action}

/// What the page says, and whether it stays.
pub type Notice {
  /// A change that was made. Quiet, and it fades.
  Said(words: String)

  /// A change that was refused. It stays until the next action, in the danger
  /// colour.
  Refused(words: String)

  /// A grant refused for want of allowance: how many grants the credential has
  /// made in the window and the Unix time in milliseconds at which a place frees.
  /// It is drawn as a refusal, with the time in a `<loom-time>` so the browser
  /// words it in the owner's own zone (protocol-change/065, the addendum on the
  /// admin page's polish).
  Throttled(used: Int, free_at_ms: Int)
}

/// A notice and the action it is about, which says where on the admin page it
/// is drawn.
pub type Spoken {
  Spoken(action: Action, notice: Notice)
}

/// The line for a notice: the page's own `role="status"` paragraph.
///
/// ## Examples
///
/// ```gleam
/// // notice.line(notice.Said("Role changed."))
/// ```
pub fn line(notice: Notice) -> Element(message) {
  case notice {
    Said(words:) ->
      html.p([attribute.class("notice-line"), attribute.role("status")], [
        html.text(words),
      ])
    Refused(words:) ->
      html.p([attribute.class("notice-refusal"), attribute.role("status")], [
        html.text(words),
      ])
    Throttled(used:, free_at_ms:) ->
      html.p([attribute.class("notice-refusal"), attribute.role("status")], [
        html.text(grants.throttle_lead(used)),
        free_at(free_at_ms),
        html.text(grants.throttle_tail),
      ])
  }
}

/// The time a place frees, as a `<loom-time>`. The instant is a number the
/// daemon wrote and travels as the element's `at` attribute, which the browser
/// draws in its own zone. The UTC time is the element's `title` and its light
/// text, which a browser that has not registered the element still shows, so the
/// words read the same either way. The server never guesses a zone.
fn free_at(milliseconds: Int) -> Element(message) {
  let utc = grants.utc_clock(milliseconds)
  element.element(
    "loom-time",
    [
      attribute.attribute("at", int.to_string(milliseconds)),
      attribute.title(utc),
    ],
    [html.text(utc)],
  )
}

/// The line for a notice that may be absent: the line, or the empty node that
/// keeps its slot.
///
/// ## Examples
///
/// ```gleam
/// // notice.maybe(None) == element.none()
/// ```
pub fn maybe(notice: Option(Notice)) -> Element(message) {
  case notice {
    Some(notice) -> line(notice)
    None -> element.none()
  }
}

/// The line, in the row of `principal`, when the action it is about names that
/// principal: a rotation, a rename, a revocation of its credentials or of one of
/// its sign-ins.
///
/// ## Examples
///
/// ```gleam
/// // notice.at_person(spoken, "guest-1a2b3c4d")
/// ```
pub fn at_person(
  spoken: Option(Spoken),
  principal: String,
) -> Element(message) {
  case spoken {
    Some(Spoken(action: grants.Rotate(principal: named), notice:))
      | Some(Spoken(action: grants.RevokeCredentials(principal: named), notice:))
      | Some(Spoken(action: grants.RevokeSignin(principal: named, ..), notice:))
      | Some(Spoken(action: grants.Rename(principal: named, ..), notice:))
      if named == principal
    -> line(notice)
    Some(_) | None -> element.none()
  }
}

/// The line, under the members' heading, when the action it is about changes
/// one member of a session: a role or a removal.
///
/// ## Examples
///
/// ```gleam
/// // notice.at_members(spoken)
/// ```
pub fn at_members(spoken: Option(Spoken)) -> Element(message) {
  case spoken {
    Some(Spoken(action: grants.SetRole(..), notice:))
    | Some(Spoken(action: grants.RevokeMembership(..), notice:)) -> line(notice)
    Some(_) | None -> element.none()
  }
}

/// The line, beside the invitation form, when the action it is about is an
/// invitation. An invitation that was made shows its claim and no line, so in
/// practice this is a refusal.
///
/// ## Examples
///
/// ```gleam
/// // notice.at_invitation(spoken)
/// ```
pub fn at_invitation(spoken: Option(Spoken)) -> Element(message) {
  case spoken {
    Some(Spoken(action: grants.Invite(..), notice:)) -> line(notice)
    Some(_) | None -> element.none()
  }
}

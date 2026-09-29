//// The notice a page draws when it has no session any more.
////
//// It sits inside the heading, after the status, so a page that ended keeps
//// every other region at the path it had and a browser event in flight still
//// names the element it meant. It is drawn from an `Ending`, a closed type
//// whose words are fixed strings, so nothing the session, the peer or an
//// error message wrote can reach it. The session identity in the advice is
//// the canonical one the daemon parsed when the page was opened; like every
//// string here it is a text node.

import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/ending.{type Ending}

/// The notice for a page that has ended, or nothing for a page that has not.
///
/// The nothing is `element.none()`, an empty text node, so the heading keeps
/// the same children whether or not the page ended.
///
/// ## Examples
///
/// ```gleam
/// // ended.view(Some(ending.PageEnded), "0192ab34cd")
/// ```
pub fn view(reason: Option(Ending), session_id: String) -> Element(message) {
  case reason {
    None -> element.none()
    Some(reason) ->
      html.section([attribute.class("ended-notice"), attribute.role("alert")], [
        html.p([attribute.class("ended-headline")], [
          html.text(ending.headline(reason)),
        ]),
        html.p([attribute.class("ended-advice")], [
          html.text(ending.advice(reason, session_id)),
        ]),
      ])
  }
}

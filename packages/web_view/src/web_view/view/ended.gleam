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
  notice(reason, ending.headline, ending.advice(_, session_id), going_back)
}

/// The notice for a page of a session on another orchestrator that has ended.
/// It is `view`'s headline with the home's advice, because `loom ui --session`
/// would name an identity this daemon does not hold.
///
/// ## Examples
///
/// ```gleam
/// // ended.relayed(Some(ending.PeerUnreachable))
/// ```
pub fn relayed(reason: Option(Ending)) -> Element(message) {
  notice(reason, ending.headline, ending.relayed_advice, going_back)
}

/// The words of `content_unavailable`.
pub const content_unavailable_words =
  "The content of this session is not available until the orchestrator that runs it answers."

/// What a page draws in place of the session's content when it has none to draw:
/// the page of a session on another orchestrator that opened, or reconnected,
/// while that orchestrator was not answering. The words say the content is
/// absent and when it will be back, so the empty lane and panes of a model that
/// was never filled are not drawn as an empty session.
///
/// ## Examples
///
/// ```gleam
/// // ended.content_unavailable()
/// ```
pub fn content_unavailable() -> Element(message) {
  html.p([attribute.class("lane-boundary"), attribute.role("status")], [
    html.text(content_unavailable_words),
  ])
}

/// The same sentence for the panel's first pane, without the status role, so a
/// screen reader announces it once. The page draws both copies.
///
/// ## Examples
///
/// ```gleam
/// // ended.content_unavailable_note()
/// ```
pub fn content_unavailable_note() -> Element(message) {
  html.p([attribute.class("lane-boundary")], [
    html.text(content_unavailable_words),
  ])
}

/// The same sentence as one tab's whole pane, for a page that has no content to
/// list under any tab. `title` is the tab's name and `kind` the suffix of the
/// pane's `pane-` class, which is what the shell reads to show only the chosen
/// tab's pane, so the pane appears under exactly the tab its content would.
/// The sentence carries no status role, since `content_unavailable` already
/// carries the one a screen reader announces.
///
/// ## Examples
///
/// ```gleam
/// // ended.content_unavailable_pane("Changes", "changes")
/// ```
pub fn content_unavailable_pane(
  title: String,
  kind: String,
) -> Element(message) {
  html.section(
    [
      attribute.class("pane"),
      attribute.class("pane-" <> kind),
      attribute.aria_label(title),
    ],
    [
      html.h2([attribute.class("panel-title")], [html.text(title)]),
      content_unavailable_note(),
    ],
  )
}

/// The notice for a home page that has ended, in the home's words, which name
/// no session (protocol-change/065). It is `view`'s notice and its classes.
///
/// ## Examples
///
/// ```gleam
/// // ended.home(Some(ending.AccessRevoked))
/// ```
pub fn home(reason: Option(Ending)) -> Element(message) {
  notice(reason, ending.home_headline, ending.home_advice, no_way_back)
}

/// The notice for an admin page that has ended, in the admin page's words
/// (protocol-change/065, the fifth pull request): its fifteen minutes and the
/// home's "Admin" button for a fresh one.
///
/// ## Examples
///
/// ```gleam
/// // ended.admin(Some(ending.PageEnded))
/// ```
pub fn admin(reason: Option(Ending)) -> Element(message) {
  notice(reason, ending.admin_headline, ending.admin_advice, no_way_back)
}

/// What a session page's notice offers after its advice: a control that goes
/// back, for an ending the browser will not recover from by itself.
///
/// A `Final` ending closes the page's socket (`ending.close`), so nothing the
/// server draws can answer a press afterwards: a button wired to the server,
/// such as the heading's home link, is dead on an ended page. `<loom-back>` is
/// answered in the browser alone, by `history.back()`, and reaches only a page
/// the tab already visited (`web_client/back`, protocol-change/051, the
/// addendum on navigation). That page is the one the person came from, usually
/// the inbox, which is why the label says "Go back" and does not name it. A
/// `Retry` ending reconnects on its own, so it offers nothing.
fn going_back(reason: Ending) -> List(Element(message)) {
  case ending.close(reason) {
    ending.Final -> [element.element("loom-back", [], [html.text("Go back")])]
    ending.Retry -> []
  }
}

/// The notice of a page that offers no way back: the home and the admin page
/// have their own controls for it.
fn no_way_back(_reason: Ending) -> List(Element(message)) {
  []
}

/// The notice for `reason`, worded by `headline` and `advice`, with `after`'s
/// controls under the advice, or nothing.
fn notice(
  reason: Option(Ending),
  headline: fn(Ending) -> String,
  advice: fn(Ending) -> String,
  after: fn(Ending) -> List(Element(message)),
) -> Element(message) {
  case reason {
    None -> element.none()
    Some(reason) ->
      html.section([attribute.class("ended-notice"), attribute.role("alert")], [
        html.p([attribute.class("ended-headline")], [
          html.text(headline(reason)),
        ]),
        html.p([attribute.class("ended-advice")], [html.text(advice(reason))]),
        ..after(reason)
      ])
  }
}

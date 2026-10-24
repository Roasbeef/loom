//// A peek at the transcript of a child that runs on another orchestrator,
//// drawn in the Strands tab in place of the list while it is open
//// (protocol-change/090).
////
//// A remote child is not a strand of this session, so focusing its card does
//// not change the strand on screen. The component opens a peek instead, which
//// asks the daemon for the newest page of the child's branch, and this module
//// draws what the peek holds: a link back to the list, the framing that says
//// whose working the page is and where it was recorded
//// (`session_view/strand_framing.transcript_head`), one block for each entry
//// with its speaker, how many entries were too large to send, and the closing
//// framing line.
////
//// The page is model text from another machine. Every word of it is a text
//// node: it is never parsed as Markdown, never a class, a key, a link or an
//// attribute, and a tag a model wrote reaches the screen as the characters it
//// is. Every class is a whole literal from this module.
////
//// The back link is the strand detail's: a control with no handler that
//// carries the position of `main`'s card, which `<loom-shell>` clicks
//// (protocol-change/051, the addendum on the marker relay). Focusing any card
//// closes the peek, so the link needs no event of its own, and this module
//// draws no handler at all.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/remote_transcript
import session_view/strand_framing
import web_view/view/strip

/// The peek's view, or `None` when no peek is open.
///
/// ## Examples
///
/// ```gleam
/// // peek.view(remote_transcript.Closed) == None
/// ```
pub fn view(state: remote_transcript.State) -> Option(Element(message)) {
  case state {
    remote_transcript.Closed -> None
    remote_transcript.Loading(child:, orchestrator:, ..) ->
      Some(
        framed(child, orchestrator, [
          html.p([attribute.class("pane-empty")], [
            html.text("Reading the transcript from " <> orchestrator <> "…"),
          ]),
        ]),
      )
    remote_transcript.Unavailable(child:, orchestrator:, reason:) ->
      Some(
        framed(child, orchestrator, [
          html.p([attribute.class("pane-empty")], [
            html.text("Transcript unavailable: " <> reason),
          ]),
        ]),
      )
    remote_transcript.Shown(child:, orchestrator:, page:) ->
      Some(framed(child, orchestrator, page_body(page)))
  }
}

/// The back link, the framing head, the body and the framing foot.
fn framed(
  child: String,
  orchestrator: String,
  body: List(Element(message)),
) -> Element(message) {
  html.div([attribute.class("strand-detail"), attribute.class("peek")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("detail-back"),
        strip.focus_attribute(0),
      ],
      [html.text("← Strands")],
    ),
    html.p([attribute.class("peek-frame")], [
      html.text(strand_framing.transcript_head(child, orchestrator)),
    ]),
    html.div([attribute.class("peek-body")], body),
    html.p([attribute.class("peek-frame")], [
      html.text(strand_framing.transcript_foot),
    ]),
  ])
}

/// The entries oldest first, each its speaker and its words, with a line for
/// older entries the page does not hold and one for entries left out.
fn page_body(page: remote_transcript.Page) -> List(Element(message)) {
  // Dispatch on page_body state.
  let older = case page.next {
    Some(_) -> [
      html.p([attribute.class("pane-empty")], [
        html.text("Older entries are not shown."),
      ]),
    ]
    None -> []
  }

  // Dispatch on page_body state.
  let omitted = case page.omitted {
    0 -> []
    count -> [
      html.p([attribute.class("pane-empty")], [
        html.text(
          int.to_string(count) <> " entries too large to show were left out.",
        ),
      ]),
    ]
  }

  // Dispatch on page_body state.
  let entries = case remote_transcript.said(page) {
    [] -> [
      html.p([attribute.class("pane-empty")], [html.text("No entries yet.")]),
    ]
    said -> list.map(said, entry)
  }

  list.flatten([older, entries, omitted])
}

/// Entry helper.
fn entry(said: remote_transcript.Said) -> Element(message) {
  html.div([attribute.class("peek-entry")], [
    html.span([attribute.class("peek-speaker")], [
      html.text(remote_transcript.speaker_word(said.speaker)),
    ]),
    html.p([attribute.class("peek-text")], [html.text(said.text)]),
  ])
}

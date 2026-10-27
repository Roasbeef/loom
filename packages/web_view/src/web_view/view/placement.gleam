//// The placement strip of a session's header: where the session's agent runs
//// and where its commands run, read in one line (the placement revamp,
//// [`docs/design-notes/placement-revamp.md`](../../../../../docs/design-notes/placement-revamp.md),
//// section 4.4).
////
//// A session's placement is two facts. The agent is the machine that holds the
//// session and drives the model, and the commands are the machine and the
//// directory the agent's tools work in. They are separate because they can
//// differ: the agent may run on a laptop while its commands run on an executor.
//// The strip says each in words, "Agent on laptop" and "Commands on exec ·
//// repo", so a person never has to infer one from the other.
////
//// The strip is a header child and decides nothing. It draws what the host
//// wrote: the daemon's name from its configuration, and the session's workspace
//// as the catalogue stores it, a directory on this machine or a name registered
//// on an executor. Both are text nodes, and a folder's whole path is a `title`
//// Lustre escapes. A session whose catalogue row the page has not read yet shows
//// the agent alone, because guessing the code's location would be wrong for an
//// executor session. A page with no machine name, as a fixture has, draws
//// nothing.
////
//// ## Examples
////
//// ```gleam
//// // placement.view("laptop", Some(listing.Registered("exec", "repo")))
//// ```

import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/listing.{type Code}

/// The strip for a session whose agent runs on `agent` and whose code is
/// `code`, or nothing when the page does not know the machine's name.
///
/// ## Examples
///
/// ```gleam
/// // placement.view("laptop", Some(listing.Folder("/work/loom")))
/// ```
pub fn view(agent: String, code: Option(Code)) -> Element(message) {
  case agent {
    "" -> element.none()
    _ ->
      html.p([attribute.class("placement-strip")], [
        tag("Agent on", agent, []),
        ..commands(agent, code)
      ])
  }
}

/// The commands' half, when the page knows where they run. A folder is on the
/// machine the agent runs on, so it is named with that machine.
fn commands(agent: String, code: Option(Code)) -> List(Element(message)) {
  case code {
    None -> []
    Some(listing.Folder(path:)) -> [
      tag("Commands on", agent <> " · " <> listing.short_path(path), [
        attribute.title(path),
      ]),
    ]
    Some(listing.Registered(..) as code) | Some(listing.Pooled(..) as code) -> [
      tag("Commands on", listing.code_words(code), []),
    ]
  }
}

/// One half of the strip: a quiet label and the machine or place it names.
fn tag(
  label: String,
  words: String,
  extra: List(attribute.Attribute(message)),
) -> Element(message) {
  html.span([attribute.class("placement-tag"), ..extra], [
    html.span([attribute.class("placement-label")], [html.text(label)]),
    html.span([attribute.class("placement-where")], [html.text(words)]),
  ])
}

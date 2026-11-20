//// The composer's draft as the browser holds it between one mount of the
//// component and the next.
////
//// The editor is an uncontrolled textarea, so the browser owns the text and
//// the server never sees it until a press. When a relayed page's box returns,
//// the socket closes once and the browser opens a new one, and Lustre mounts a
//// fresh component into the same document: the composer element and its
//// textarea are new, and the typed text is gone. The document itself survives,
//// so the draft is kept there, in memory, and put back when the new element
//// joins the page.
////
//// The draft is held as one attribute of the document's root element,
//// `data-loom-draft`, whose value is a JSON object naming the page's route and
//// the text. The route is the `route` attribute of the server component that
//// holds the composer. It is the page's own address plus `/ws`, so it names the
//// session, and the orchestrator for a relayed page, and a draft is put back
//// only into the page it was typed in. One attribute holds one draft because a
//// document holds one page, and a switch to another session is a navigation to
//// a new document. Nothing is written to storage, so a draft does not outlive
//// the tab and nothing reaches disk.
////
//// A press clears it: the element clears its editor at the press, which writes
//// the empty text, and a refusal writes the returned text again. This module
//// imports neither Lustre nor the DOM binding, so its tests run on Node.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

/// The attribute of the document's root element that holds the draft.
pub const attribute_name = "data-loom-draft"

/// The most characters of a draft the browser keeps. A prompt the page sends is
/// bounded by the daemon, and a draft longer than this is kept cut rather than
/// held twice without limit.
pub const limit = 100_000

/// The draft held for `key`, or an empty string when the attribute holds none,
/// holds another page's, or holds something that is not a draft.
///
/// ## Examples
///
/// ```gleam
/// let raw = draft_rule.holding("/ui/p/a/ws", "fix the test")
/// assert draft_rule.held(raw, "/ui/p/a/ws") == "fix the test"
/// assert draft_rule.held(raw, "/ui/p/b/ws") == ""
/// ```
pub fn held(raw: Option(String), key: String) -> String {
  case raw {
    None -> ""
    Some(raw) ->
      case json.parse(raw, decoder()) {
        Ok(#(held_key, text)) if held_key == key -> text
        Ok(_) | Error(_) -> ""
      }
  }
}

/// The attribute value that holds `text` for `key`, or `None` when the text is
/// empty and the attribute is to be removed.
///
/// ## Examples
///
/// ```gleam
/// assert draft_rule.holding("/ui/p/a/ws", "  ") == None
/// ```
pub fn holding(key: String, text: String) -> Option(String) {
  case string.trim(text) {
    "" -> None
    _ ->
      Some(
        json.to_string(
          json.object([
            #("key", json.string(key)),
            #("text", json.string(cut(text))),
          ]),
        ),
      )
  }
}

// The text cut to `limit` characters. It runs on every keystroke, and slicing
// walks the text by grapheme, so a text whose byte size is within the limit,
// which has no more characters than bytes, is returned as it is.
fn cut(text: String) -> String {
  case string.byte_size(text) <= limit {
    True -> text
    False -> string.slice(text, 0, limit)
  }
}

fn decoder() -> decode.Decoder(#(String, String)) {
  use key <- decode.field("key", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(#(key, text))
}

//// Compact prompt attachments for the terminal composer.
////
//// A terminal paste can contain far more text than the one-row editor can
//// usefully show. The composer keeps those bytes out of presentation state,
//// but expands them back into the ordinary text prompt at the gateway edge.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui_gleam/text_hygiene

const compact_token_threshold = 400

const compact_line_threshold = 8

/// One pasted text attachment and its deliberately approximate token count.
pub type Attachment {
  Attachment(text: String, estimated_tokens: Int)
}

/// Whether pasted text belongs inline in the editor or behind an attachment.
pub type Paste {
  Inline(text: String)
  Compact(attachment: Attachment)
}

/// Classifies a paste without changing the bytes that will reach the server.
pub fn classify(text: String) -> Paste {
  let estimated_tokens = estimate_tokens(text)
  let line_count = list.length(string.split(text, "\n"))
  case
    estimated_tokens >= compact_token_threshold
    || line_count >= compact_line_threshold
  {
    True -> Compact(Attachment(text:, estimated_tokens:))
    False -> Inline(text)
  }
}

/// Estimates tokens from UTF-8 bytes and always labels the result approximate.
pub fn estimate_tokens(text: String) -> Int {
  let bytes = string.byte_size(text)
  case bytes == 0 {
    True -> 0
    False -> int.max(1, { bytes + 3 } / 4)
  }
}

/// Describes all compact pastes in the prompt border.
pub fn summary(attachments: List(Attachment)) -> Option(String) {
  case attachments {
    [] -> None
    [Attachment(estimated_tokens:, ..)] ->
      Some("pasted ~" <> token_count(estimated_tokens) <> " tokens")
    _ -> {
      let total =
        list.fold(attachments, 0, fn(total, attachment) {
          let Attachment(estimated_tokens:, ..) = attachment
          total + estimated_tokens
        })
      Some(
        int.to_string(list.length(attachments))
        <> " pastes · ~"
        <> token_count(total)
        <> " tokens",
      )
    }
  }
}

/// Expands attachment bytes after the editable instruction text.
pub fn expand(input: String, attachments: List(Attachment)) -> String {
  let pasted =
    attachments
    |> list.map(fn(attachment) {
      let Attachment(text:, ..) = attachment
      text
    })
    |> string.join("\n\n")
  case input, pasted {
    "", pasted -> pasted
    input, "" -> input
    input, pasted -> input <> "\n\n" <> pasted
  }
}

/// Drops the newest attachment when backspace reaches an empty editor.
pub fn drop_last(attachments: List(Attachment)) -> List(Attachment) {
  case list.reverse(attachments) {
    [] -> []
    [_, ..rest] -> list.reverse(rest)
  }
}

/// Bounds a large durable user turn until transcript detail is requested.
pub fn transcript_text(text: String, details_expanded: Bool) -> String {
  case classify(text), details_expanded {
    Compact(Attachment(estimated_tokens:, ..)), False ->
      preview(text, 120)
      <> "  [~"
      <> token_count(estimated_tokens)
      <> " tokens · Ctrl+G to expand]"
    _, _ -> text
  }
}

fn preview(text: String, limit: Int) -> String {
  let one_line = text_hygiene.single_line(text)
  case string.drop_start(one_line, limit) {
    "" -> one_line
    _ -> string.slice(one_line, 0, limit - 1) <> "…"
  }
}

fn token_count(value: Int) -> String {
  case value >= 1_000_000, value >= 1000 {
    True, _ -> int.to_string(value / 1_000_000) <> "m"
    False, True -> int.to_string(value / 1000) <> "k"
    False, False -> int.to_string(value)
  }
}

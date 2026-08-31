//// Text and image attachments for the terminal composer.
////
//// A terminal paste can contain far more text than the one-row editor can
//// usefully show. The composer keeps those bytes out of presentation state,
//// but expands them back into the ordinary text prompt at the gateway edge.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui_gleam/image_drop
import tui_gleam/text_hygiene

const compact_token_threshold = 400

const compact_line_threshold = 8

/// One attachment retained outside the editable prompt text.
pub type Attachment {
  /// A compact pasted-text attachment.
  Attachment(
    /// The exact pasted bytes retained until submission.
    text: String,
    /// A display-only estimate that must never replace the exact bytes.
    estimated_tokens: Int,
  )
  /// A validated local image ready for a typed prompt-content block.
  ImageAttachment(image: image_drop.Image)
}

/// Whether pasted text belongs inline in the editor or behind an attachment.
pub type Paste {
  /// Text small enough for the ordinary one-row editor.
  Inline(
    /// The exact pasted bytes.
    text: String,
  )
  /// Text retained outside the editor so rendering stays bounded.
  Compact(
    /// The attachment that owns the exact bytes and its approximate size.
    attachment: Attachment,
  )
}

/// Classifies a paste without changing the bytes that will reach the server.
///
/// ## Examples
///
/// ```gleam
/// assert composer.classify("small") == composer.Inline("small")
/// ```
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
///
/// ## Examples
///
/// ```gleam
/// assert composer.estimate_tokens("loom") == 1
/// ```
pub fn estimate_tokens(text: String) -> Int {
  let bytes = string.byte_size(text)
  case bytes == 0 {
    True -> 0
    False -> int.max(1, { bytes + 3 } / 4)
  }
}

/// Describes all compact pastes in the input row.
///
/// ## Examples
///
/// ```gleam
/// let attachment = composer.Attachment("data", 1)
/// assert composer.summary([attachment]) == Some("pasted ~1 tokens")
/// ```
pub fn summary(attachments: List(Attachment)) -> Option(String) {
  case attachments {
    [] -> None
    [Attachment(estimated_tokens:, ..)] ->
      Some("pasted ~" <> token_count(estimated_tokens) <> " tokens")
    [
      ImageAttachment(image: image_drop.Image(
        filename:,
        mime_type:,
        byte_size:,
        ..,
      )),
    ] ->
      Some(
        filename
        <> " · "
        <> mime_type
        <> " · "
        <> int.to_string(byte_size)
        <> " B",
      )
    attachments ->
      case has_images(attachments) {
        False ->
          Some(
            int.to_string(list.length(attachments))
            <> " pastes · ~"
            <> token_count(text_token_total(attachments))
            <> " tokens",
          )
        True ->
          attachments
          |> list.map(attachment_summary)
          |> string.join(" · ")
          |> Some
      }
  }
}

fn text_token_total(attachments: List(Attachment)) -> Int {
  list.fold(attachments, 0, fn(total, attachment) {
    case attachment {
      Attachment(estimated_tokens:, ..) -> total + estimated_tokens
      ImageAttachment(..) -> total
    }
  })
}

fn attachment_summary(attachment: Attachment) -> String {
  case attachment {
    Attachment(estimated_tokens:, ..) ->
      "paste ~" <> token_count(estimated_tokens) <> " tokens"
    ImageAttachment(image_drop.Image(filename:, mime_type:, byte_size:, ..)) ->
      filename <> " " <> mime_type <> " " <> int.to_string(byte_size) <> " B"
  }
}

/// Expands attachment bytes after the editable instruction text.
///
/// ## Examples
///
/// ```gleam
/// let attachment = composer.Attachment("context", 2)
/// assert composer.expand("review", [attachment]) == "review\n\ncontext"
/// ```
pub fn expand(input: String, attachments: List(Attachment)) -> String {
  let pasted =
    attachments
    |> list.filter_map(fn(attachment) {
      case attachment {
        Attachment(text:, ..) -> Ok(text)
        ImageAttachment(..) -> Error(Nil)
      }
    })
    |> string.join("\n\n")
  case input, pasted {
    "", pasted -> pasted
    input, "" -> input
    input, pasted -> input <> "\n\n" <> pasted
  }
}

/// Drops the newest attachment when backspace reaches an empty editor.
///
/// ## Examples
///
/// ```gleam
/// let first = composer.Attachment("first", 2)
/// let second = composer.Attachment("second", 2)
/// assert composer.drop_last([first, second]) == [first]
/// ```
pub fn drop_last(attachments: List(Attachment)) -> List(Attachment) {
  case list.reverse(attachments) {
    [] -> []
    [_, ..rest] -> list.reverse(rest)
  }
}

/// Returns validated images in the order the operator dropped them.
///
/// ## Examples
///
/// ```gleam
/// assert composer.images([]) == []
/// ```
///
pub fn images(attachments: List(Attachment)) -> List(image_drop.Image) {
  list.filter_map(attachments, fn(attachment) {
    case attachment {
      Attachment(..) -> Error(Nil)
      ImageAttachment(image:) -> Ok(image)
    }
  })
}

/// Reports whether the composer holds any image attachment.
///
/// ## Examples
///
/// ```gleam
/// assert !composer.has_images([])
/// ```
///
pub fn has_images(attachments: List(Attachment)) -> Bool {
  images(attachments) != []
}

/// Bounds a large durable user turn until transcript detail is requested.
///
/// ## Examples
///
/// ```gleam
/// assert composer.transcript_text("short", False) == "short"
/// ```
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

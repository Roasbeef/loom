//// Text and image attachments for the terminal composer.
////
//// A terminal paste can contain far more text than the one-row editor can
//// usefully show. The composer keeps those bytes out of presentation state,
//// but expands them back into the ordinary text prompt at the gateway edge.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui/image_drop
import tui/text_hygiene

const compact_token_threshold = 400

const compact_line_threshold = 8

/// The most images retained in one unsent prompt.
pub const max_image_attachments = 4

/// The aggregate raw image bytes retained in one unsent prompt.
pub const max_image_attachment_bytes = image_drop.max_image_bytes

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
        text_hygiene.single_line(filename)
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
      text_hygiene.single_line(filename)
      <> " "
      <> mime_type
      <> " "
      <> int.to_string(byte_size)
      <> " B"
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

/// Admits one attachment without letting image memory grow without bound.
///
/// ## Examples
///
/// ```gleam
/// assert composer.admit_attachment([], composer.Attachment("text", 1))
///   == Ok([composer.Attachment("text", 1)])
/// ```
///
@internal
pub fn admit_attachment(
  attachments: List(Attachment),
  attachment: Attachment,
) -> Result(List(Attachment), String) {
  case attachment {
    Attachment(..) -> Ok(list.append(attachments, [attachment]))
    ImageAttachment(image_drop.Image(byte_size:, ..)) -> {
      let current_images = images(attachments)
      let current_bytes =
        list.fold(current_images, 0, fn(total, image) {
          let image_drop.Image(byte_size:, ..) = image
          total + byte_size
        })
      case
        list.drop(current_images, max_image_attachments - 1) != [],
        current_bytes + byte_size > max_image_attachment_bytes
      {
        True, _ -> Error("a prompt may attach at most four images")
        _, True -> Error("a prompt may attach at most 20 MiB of images")
        False, False -> Ok(list.append(attachments, [attachment]))
      }
    }
  }
}

/// The marker every message the harness itself injected begins with.
///
/// A triggered project rule (`client/rules.injection`) and a scheduled
/// heartbeat (`client/schedule.injection`) both arrive as ordinary user
/// turns, because a user turn is the only shape a provider API has for
/// context the harness supplies. They are not turns from the person at
/// the keyboard, and reading a screen full of standing configuration
/// every time one fires is noise: the transcript should say *which*
/// standing instruction fired and let the reader open it if they care.
pub const harness_injection_prefix = "[loom] "

/// The single line a harness injection collapses to, or `None` when this
/// is not one.
///
/// The contract this rests on is deliberately narrow, and it is the
/// injecting module's to keep: **a harness injection's first line names
/// it completely.** Both injectors write that line as an attribution —
/// `[loom] scheduled heartbeat "pulse" (late)` — with the fenced body
/// below it, so collapsing to the first line loses nothing a reader
/// needs to decide whether to expand. Parsing that line rather than the
/// body is what keeps this client from having to know the two injectors'
/// prose, which is theirs to reword.
///
/// A single-line `[loom] ` message is already its own summary and is
/// returned unchanged by the caller rather than collapsed to itself.
///
/// ## Examples
///
/// ```gleam
/// assert composer.harness_injection_summary("[loom] a \"b\"\n\nbody")
///   == Some("[loom] a \"b\"")
/// ```
///
/// ```gleam
/// assert composer.harness_injection_summary("ordinary turn") == None
/// ```
pub fn harness_injection_summary(text: String) -> Option(String) {
  use <- bool.guard(
    when: !string.starts_with(text, harness_injection_prefix),
    return: None,
  )
  case string.split_once(text, "\n") {
    Ok(#(first, _body)) -> Some(first)
    Error(Nil) -> None
  }
}

/// Bounds a large durable user turn until transcript detail is requested.
///
/// Two different kinds of "too much to read" meet here and are answered
/// differently. A harness injection has a *structure* — an attribution
/// line and a fenced body — so it collapses to that line. An ordinary
/// large paste has none, so it keeps the byte-estimate preview, which is
/// the honest summary of something whose shape nothing here knows.
///
/// ## Examples
///
/// ```gleam
/// assert composer.transcript_text("short", False) == "short"
/// ```
///
/// ```gleam
/// // an injection collapses to its attribution line
/// assert composer.transcript_text("[loom] rule \"r\"\n\nbody", False)
///   == "[loom] rule \"r\"  [Ctrl+G to expand]"
/// ```
pub fn transcript_text(text: String, details_expanded: Bool) -> String {
  use <- bool.lazy_guard(when: details_expanded, return: fn() { text })
  case harness_injection_summary(text) {
    Some(attribution) -> attribution <> "  [Ctrl+G to expand]"
    None -> bounded_paste(text)
  }
}

// The pre-existing paste bound, unchanged: an oversized paste previews
// its own first bytes and says roughly how many there are. `Inline` and
// an image attachment both render whole — one is small by construction,
// the other is not text.
fn bounded_paste(text: String) -> String {
  case classify(text) {
    Compact(Attachment(estimated_tokens:, ..)) ->
      preview(text, 120)
      <> "  [~"
      <> token_count(estimated_tokens)
      <> " tokens · Ctrl+G to expand]"
    Compact(ImageAttachment(..)) | Inline(..) -> text
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

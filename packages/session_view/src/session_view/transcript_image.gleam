//// The images a transcript row carries, and the name a host gives each.
////
//// `transcript_lines` draws an image as a text row, `[image image/png]`,
//// because a row is a speaker and a string. A host that can show a picture
//// needs the bytes and a way to name them, and this module is where both
//// come from. The rows and the pictures are two views of one durable entry:
//// the rows are what every host draws, and the pictures are what a host
//// that can draw an image adds beneath them. Nothing here changes a row.
////
//// A picture belongs to the row that carries it. A person's message owns
//// the images it was sent with, and a tool result owns the images the tool
//// returned, which a host draws with the call they answer. Each is named by
//// the key of the block or step it belongs to (`transcript_lines.Block.key`,
//// `turns.Step.key`) and its position among that row's images, so a name
//// says which row it is under and says nothing the row's author wrote.
////
//// The bytes stay in the entry. An `Image` holds the base64 text the entry
//// already holds, so a host that draws the same image twice, or looks one up
//// to serve it, shares one binary and copies none.

import core/entry
import core/message
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/transcript_lines

/// One image of a transcript row, as its entry holds it.
pub type Image {
  Image(
    /// The media type the entry declares. It is a claim: a host that serves
    /// the bytes checks them against `pasted_image.media_type` as well.
    mime_type: String,
    /// The image bytes, base64 encoded.
    data: String,
  )
}

/// The images a durable entry carries, in the order its content holds them:
/// a user message's `UserImage` blocks or a tool result's `ToolResultImage`
/// blocks. An assistant message, a compaction and every other entry carry
/// none.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_image.of_entry(entry) == [transcript_image.Image("image/png", "iVBOR...")]
/// ```
pub fn of_entry(value: entry.Entry) -> List(Image) {
  case value {
    entry.MessageEntry(message: sent, ..) -> of_message(sent)
    entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> []
  }
}

/// The images of a message, as `of_entry` reads them.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_image.of_message(message.UserMessage(..)) == []
/// ```
pub fn of_message(sent: message.AgentMessage) -> List(Image) {
  case sent {
    message.UserMessage(content:, ..) ->
      list.filter_map(content, fn(block) {
        case block {
          message.UserImage(data:, mime_type:) -> Ok(Image(mime_type:, data:))
          message.UserText(..) -> Error(Nil)
        }
      })
    message.ToolResultMessage(content:, ..) ->
      list.filter_map(content, fn(block) {
        case block {
          message.ToolResultImage(data:, mime_type:) ->
            Ok(Image(mime_type:, data:))
          message.ToolResultText(..) -> Error(Nil)
        }
      })
    message.AssistantMessage(..) | message.CustomMessage(..) -> []
  }
}

/// The images of a tool call's result, when the window holds one. A call
/// that has not been answered has none.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_image.of_outcome(None) == []
/// ```
pub fn of_outcome(outcome: Option(message.AgentMessage)) -> List(Image) {
  case outcome {
    Some(sent) -> of_message(sent)
    None -> []
  }
}

/// The images a transcript block carries: those of the durable entry that
/// drew it. A block that a tool group, a notice, the advisor or a spacer
/// drew carries none of its own; a tool group's images belong to its steps.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_image.of_block(block) == []
/// ```
pub fn of_block(block: transcript_lines.Block) -> List(Image) {
  case block.source {
    transcript_lines.FromEntry(value:) -> of_entry(value)
    transcript_lines.FromTools(..)
    | transcript_lines.FromNotice
    | transcript_lines.FromAdvisor
    | transcript_lines.FromSpacer -> []
  }
}

/// The name of the row a block or step key stands for, as one path segment.
///
/// A block's key holds digits, `.` and `~`, and a step's adds `/` between the
/// block's key and the call's index. The slash is what a path cannot carry, so
/// it becomes `-`. The name is a function of the key alone and is compared,
/// never parsed: a host finds the row whose name equals the one it was asked
/// for.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_image.ref("7.0") == "7.0"
/// assert transcript_image.ref("7.0/2") == "7.0-2"
/// ```
pub fn ref(key: String) -> String {
  string.replace(key, "/", "-")
}

//// The vision routing rule: an image-bearing request never reaches a
//// model that cannot read it (issue #358).
////
//// A strand's model is chosen once, at creation, and nothing on the
//// request path used to ask whether the *request* — not the strand —
//// carries an image. The OpenAI adapter encodes `UserImage` as a
//// data-URL `image_url` block on every request, so an image dropped on a
//// text-only model was silently accepted by the harness and silently
//// ignored or refused by the provider: the model answers that it cannot
//// see the image, or worse, describes a *previous* turn's image and
//// hedges. The catalogue's `vision` role existed and parsed, but nothing
//// resolved through it.
////
//// This module owns the three decisions that close that gap. All three
//// are pure functions of the request's own content plus durable state,
//// so a re-attempt after a crash takes exactly the decision the
//// original attempt took:
////
//// - **Admission** (`image_bearing`, `admission`). A request whose
////   current turn carries an image, on a strand whose model cannot read
////   images, must find a usable `vision` route or be refused
////   in band with a worded reason — before the planner mints any ids,
////   at the same gate that already refuses an unresolvable identity. An
////   operator who routes `vision` to an entry that cannot read images
////   has written a misconfiguration and hears about it as one.
//// - **Routing** (`routed_target`). Such a request dispatches through
////   the `vision` chain — `ForRole(Vision)`, so a retryable failure
////   walks that chain inside the one attempt, exactly as an on-route
////   generation walks its own. The strand's system prompt and tool list
////   travel with the request unchanged: the model answering is still
////   *this strand's* turn, only its eyes are borrowed. The strand's
////   per-turn thinking budget rides along as on every other dispatch.
//// - **Placeholders** (`placeholdered`). A request dispatched to an
////   identity that cannot read images — any request that was not
////   re-routed — has every user or tool-result image block in its projection
////   replaced with a text placeholder naming the mime type. The
////   transform is transient: it is applied to the projection the driver
////   just read, never written down, so the durable transcript keeps the
////   image for a later vision-capable turn, exactly as it keeps it for
////   the vision model that reads the whole context on a re-routed
////   request.
////
//// The current turn decides because that is what this request must be
//// answered against. A new attributed user prompt or a settled assistant
//// response bounds it; a tool call and its result are steps inside it, so the
//// second request of an image turn stays on the model that saw the
//// image. An older image, on a request whose current turn is text,
//// stays in the projection of a vision-capable model (the model may
//// need to refer back) and is placeholdered on a text-only one (the
//// model cannot read it on any turn).

import core/message.{
  type AgentMessage, type UserBlock, AssistantMessage, CustomMessage,
  ToolResultImage, ToolResultMessage, ToolResultText, ToolUse, UserImage,
  UserMessage, UserText,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import machine/operation.{OperationError}
import machine/planner.{type RequestAdmission, AdmissionUnavailable}
import machine/strand.{type ModelIdentity}
import provider/model.{type RequestTarget, type ResolvedModel, Vision}

/// The placeholder a text-only projection shows in an image block's
/// place. The mime type travels because it is the one fact about the
/// image the text can still carry, and "described earlier in this
/// conversation" tells the model the pixels exist in durable history a
/// later vision-capable turn may read.
///
/// ## Examples
///
/// ```gleam
/// // assert vision.placeholder("image/png")
/// //   == message.UserText("[image: image/png, ...]", option.None)
/// ```
///
pub fn placeholder(mime_type: String) -> UserBlock {
  UserText(
    text: "[image: " <> mime_type <> ", described earlier in this conversation]",
    text_signature: None,
  )
}

/// Whether the projection's *current turn* carries an image — the
/// classification admission routes on.
///
/// The newest attributed user prompt begins a turn. Run-start digests have
/// no human origin, so they remain inside that prompt's turn, as do assistant
/// tool calls and their results. A settled assistant response also closes a
/// turn, preserving the boundary for older transcripts without attribution.
///
/// Failed assistant messages are removed by session projection. Relying only
/// on assistant boundaries would therefore route a later text prompt through
/// vision forever after a rejected image request. Attribution survives that
/// projection and identifies the new prompt without inspecting its text.
///
/// ## Examples
///
/// ```gleam
/// // assert vision.image_bearing([]) == False
/// ```
///
pub fn image_bearing(messages: List(AgentMessage)) -> Bool {
  current_turn(messages)
  |> list.any(fn(entry) {
    case entry {
      UserMessage(content:, ..) -> list.any(content, is_image)
      ToolResultMessage(content:, ..) ->
        list.any(content, fn(block) {
          case block {
            ToolResultImage(..) -> True
            ToolResultText(..) -> False
          }
        })
      AssistantMessage(..) | CustomMessage(..) -> False
    }
  })
}

// Walk newest-first until the current human prompt or a settled answer.
// The attributed prompt belongs to the result; the preceding answer does not.
// Digests and tool steps stay with the prompt that caused them.
fn current_turn(messages: List(AgentMessage)) -> List(AgentMessage) {
  collect_turn(list.reverse(messages), [])
}

fn collect_turn(
  newest_first: List(AgentMessage),
  collected: List(AgentMessage),
) -> List(AgentMessage) {
  case newest_first {
    [] -> collected
    [UserMessage(origin: Some(_), ..) as prompt, ..] -> [prompt, ..collected]
    [AssistantMessage(stop_reason: ToolUse, ..) as step, ..rest] ->
      collect_turn(rest, [step, ..collected])
    [AssistantMessage(..), ..] -> collected
    [UserMessage(..) as step, ..rest]
    | [ToolResultMessage(..) as step, ..rest]
    | [CustomMessage(..) as step, ..rest] ->
      collect_turn(rest, [step, ..collected])
  }
}

fn is_image(block: UserBlock) -> Bool {
  case block {
    UserImage(..) -> True
    UserText(..) -> False
  }
}

/// The refusal for an image-bearing request whose strand model cannot
/// read images and whose vision route does not resolve.
///
/// The reason names both the model and the missing route, because those
/// are the two things an operator can act on: switch the strand, or
/// write the chain. The refusal is the feature — a model that would
/// answer "I cannot see the image" is never asked, and refusing at
/// admission rather than at dispatch is what makes it cost nothing
/// durable: the planner mints no ids under a refusal.
pub fn no_route_refusal(identity: ModelIdentity) -> RequestAdmission {
  AdmissionUnavailable(error: OperationError(
    code: "image_unsupported",
    message: "the model "
      <> identity.provider
      <> "/"
      <> identity.model_id
      <> " cannot read images and no vision route resolves; configure a"
      <> " [roles] vision chain or switch the strand to a model that reads"
      <> " images",
    details: None,
  ))
}

/// The refusal for a vision chain whose head the catalogue itself
/// declares unable to read images.
///
/// A routed-but-blind chain is not the caller's fault and not a gap the
/// request can route around; it names the entry that must change, which
/// is the difference between this refusal and `no_route_refusal`.
pub fn blind_route_refusal(head: ResolvedModel) -> RequestAdmission {
  AdmissionUnavailable(error: OperationError(
    code: "vision_misconfigured",
    message: "the vision route resolves to "
      <> head.provider
      <> "/"
      <> head.model_id
      <> ", which the catalogue declares unable to read images",
    details: None,
  ))
}

/// The dispatch target for one image-bearing request whose strand model
/// cannot read images: the `vision` chain, walked as a chain.
///
/// The caller resolves the head once, at admission, and hands the same
/// resolution here — so a chain that moved between admission and
/// dispatch cannot route one request's two ends at two different
/// models. The thinking overlay is the strand's own per-turn level,
/// carried by the caller onto every target the walk attempts, exactly
/// as `wiring.request_target` carries it for the strand's own route.
pub fn routed_target(
  thinking thinking: Option(model.ThinkingLevel),
) -> RequestTarget {
  model.ForRole(role: Vision, thinking:)
}

/// Replaces every user or tool-result image block in a projection with the
/// placeholder, for a request dispatched to an identity that cannot read
/// images.
///
/// Every image, not just the newest turn's: an image the model cannot
/// read is invalid input on *any* turn, and a provider that rejects one
/// stale image would fail a request whose own newest message is plain
/// text. The images stay in the durable store; only this request's
/// transient copy of them is rewritten.
///
/// ## Examples
///
/// ```gleam
/// // assert vision.placeholdered([]) == []
/// ```
///
pub fn placeholdered(messages: List(AgentMessage)) -> List(AgentMessage) {
  list.map(messages, fn(entry) {
    case entry {
      UserMessage(content:, timestamp:, origin:) ->
        UserMessage(
          content: list.map(content, replace_image),
          timestamp:,
          origin:,
        )
      ToolResultMessage(content:, ..) as result ->
        ToolResultMessage(
          ..result,
          content: list.map(content, fn(block) {
            case block {
              ToolResultImage(_, mime_type) ->
                ToolResultText(
                  "[image: "
                    <> mime_type
                    <> ", described earlier in this conversation]",
                  None,
                )
              ToolResultText(..) -> block
            }
          }),
        )
      AssistantMessage(..) | CustomMessage(..) -> entry
    }
  })
}

fn replace_image(block: UserBlock) -> UserBlock {
  case block {
    UserImage(_data, mime_type) -> placeholder(mime_type)
    UserText(..) -> block
  }
}

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
////   newest user message carries an image, on a strand whose model
////   cannot read images, must find a usable `vision` route or be refused
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
////   re-routed — has every `UserImage` block in its projection
////   replaced with a text placeholder naming the mime type. The
////   transform is transient: it is applied to the projection the driver
////   just read, never written down, so the durable transcript keeps the
////   image for a later vision-capable turn, exactly as it keeps it for
////   the vision model that reads the whole context on a re-routed
////   request.
////
//// The newest user message decides because that is the message this
//// request must be answered against. An older image, on a request whose
//// newest turn is text, stays in the projection of a vision-capable
//// model (the model may need to refer back) and is placeholdered on a
//// text-only one (the model cannot read it on any turn).

import core/message.{
  type AgentMessage, type UserBlock, UserImage, UserMessage, UserText,
}
import gleam/list
import gleam/option.{type Option, None}
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
/// The current turn is everything after the newest settled assistant
/// message. That boundary, rather than "the newest user message", is
/// what makes the classification hold on a real session: the run-start
/// hooks inject the notes digest, the memory digest and extension
/// notes as user messages *after* the operator's prompt, so the
/// newest-user-message walk would classify a digest and silently
/// placeholder the operator's image — the exact failure the rule
/// exists to remove. Injections are harness-authored context inside the
/// current turn only when the operator's image is there too, and
/// everything an assistant has already answered is a past turn whose
/// images a vision model may still read and a text-only one is
/// placeholdered on anyway.
///
/// No prefix-sniffing and no authorship check: the boundary is the
/// conversation's own shape, so a reminder, a digest, or a future
/// injection kind needs no enumeration here.
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
      _ -> False
    }
  })
}

// The messages after the newest settled assistant response, or the
// whole projection when no assistant has answered yet — a fresh
// session's first turn is all current turn.
fn current_turn(messages: List(AgentMessage)) -> List(AgentMessage) {
  // The tail after the newest assistant message, when one has
  // settled; `list.take_right` over the reversed list is the same
  // walk without naming the constructor at all.
  messages
  |> list.reverse
  |> list.take_while(fn(entry) {
    case entry {
      UserMessage(..) -> True
      _ -> False
    }
  })
  |> list.reverse
}

fn is_image(block: UserBlock) -> Bool {
  case block {
    UserImage(..) -> True
    _ -> False
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

/// Replaces every `UserImage` block in a projection with the
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
      other -> other
    }
  })
}

fn replace_image(block: UserBlock) -> UserBlock {
  case block {
    UserImage(_data, mime_type) -> placeholder(mime_type)
    text -> text
  }
}

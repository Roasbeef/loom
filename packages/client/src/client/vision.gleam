//// The vision routing rule (issue #358), as `client` names it.
////
//// The rule itself, its reasoning and its tests of record moved to
//// `harness/vision` when the provider-routing core left `client/wiring`
//// (issue #1030, `docs/design-notes/harness-extraction.md`): an embedder
//// needs the same image-bearing classification and placeholders the daemon
//// uses. This module keeps the names `client` and its test suite have always
//// used, each a one-line delegation, so there is one implementation and no
//// second place for the two to drift.
////
//// ## Flow
////
//// `image_bearing` classifies a projection; `no_route_refusal` and
//// `blind_route_refusal` word the two admission refusals; `routed_target` is
//// the vision chain's dispatch target; `placeholdered` rewrites a projection
//// for a model which cannot read images; `placeholder` is the one block it
//// writes.

import core/message.{type AgentMessage, type UserBlock}
import gleam/option.{type Option}
import harness/vision
import machine/planner.{type RequestAdmission}
import machine/strand.{type ModelIdentity}
import provider/model.{type RequestTarget, type ResolvedModel}

/// The placeholder a text-only projection shows in an image block's place.
///
/// ## Examples
///
/// ```gleam
/// // assert vision.placeholder("image/png")
/// //   == message.UserText("[image: image/png, ...]", option.None)
/// ```
///
pub fn placeholder(mime_type: String) -> UserBlock {
  vision.placeholder(mime_type)
}

/// Whether the projection's current turn carries an image.
///
/// ## Examples
///
/// ```gleam
/// // assert vision.image_bearing([]) == False
/// ```
///
pub fn image_bearing(messages: List(AgentMessage)) -> Bool {
  vision.image_bearing(messages)
}

/// The refusal for an image-bearing request whose strand model cannot read
/// images and whose vision route does not resolve.
///
/// ## Examples
///
/// ```gleam
/// // vision.no_route_refusal(identity)
/// ```
///
pub fn no_route_refusal(identity: ModelIdentity) -> RequestAdmission {
  vision.no_route_refusal(identity)
}

/// The refusal for a vision chain whose head the catalogue declares unable to
/// read images.
///
/// ## Examples
///
/// ```gleam
/// // vision.blind_route_refusal(head)
/// ```
///
pub fn blind_route_refusal(head: ResolvedModel) -> RequestAdmission {
  vision.blind_route_refusal(head)
}

/// The dispatch target for one image-bearing request: the vision chain.
///
/// ## Examples
///
/// ```gleam
/// // vision.routed_target(thinking: option.None)
/// ```
///
pub fn routed_target(
  thinking thinking: Option(model.ThinkingLevel),
) -> RequestTarget {
  vision.routed_target(thinking:)
}

/// Replaces every user or tool-result image block with the placeholder.
///
/// ## Examples
///
/// ```gleam
/// // assert vision.placeholdered([]) == []
/// ```
///
pub fn placeholdered(messages: List(AgentMessage)) -> List(AgentMessage) {
  vision.placeholdered(messages)
}

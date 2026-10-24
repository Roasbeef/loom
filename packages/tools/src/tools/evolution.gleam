//// The host-owned doors for immutable self-extension candidates.
////
//// Evolution has no direct model tools. A program reaches these doors
//// through `cap/evolution`, and `client/evolution/capability` builds the six
//// closures for one execution from the `Door` the session assembled. This
//// module is the seam between the two: the shape of the doors, with no
//// declaration, schema or tool name of its own.
////
//// Authoring and testing never grant activation authority. Discovery returns
//// exact candidate and generation tokens; invocation requires both, so an old
//// schema cannot silently execute a replacement implementation.

import core/json.{type JsonValue}
import tools/tool.{type Ctx, type ToolOutcome}

/// The host-owned lifecycle doors: five over the catalogue and one over the
/// session's own transcript. No operator authority crosses this seam.
pub type Door {
  Door(
    /// Captures authorized source into an immutable proposal.
    propose: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Runs candidate-owned tests and persists their evidence.
    test_candidate: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Reads visible immutable bytes and evidence.
    inspect: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Discovers selected versions and their precise callable contracts.
    catalogue: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Calls an exact discovered candidate under the current caller's policy.
    invoke: fn(Ctx, JsonValue) -> ToolOutcome,
    /// Reads bounded excerpts of the session's own transcript.
    trace: fn(Ctx, JsonValue) -> ToolOutcome,
  )
}

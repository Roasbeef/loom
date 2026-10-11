//// What an executor tells its orchestrator when a session's scope attaches.
////
//// The remote call host is generic over its census so the call mechanics do
//// not depend on how a workspace is assembled. This module fixes that
//// parameter for real sessions: the workspace plane's own `Census`, plus the
//// three things a local session reads from its plane by calling a function,
//// which a remote session must receive as data instead.
////
//// Everything here crosses TLS distribution, so every field is plain data:
//// strings, numbers, lists, records of those, and one `Subject`. A closure
//// placed in any of these types would serialize on the executor and fail on
//// the orchestrator, so a test walks a real census and refuses any function
//// value it finds.

import broker/broker
import client/workspace_plane
import gleam/erlang/process.{type Subject}
import tools/tool

/// The census an attach reply carries for a real workspace.
pub type RemoteCensus {
  RemoteCensus(
    /// The workspace plane's census, as a local session's plane reports it.
    census: workspace_plane.Census,
    /// The workspace tools in registration order. The orchestrator builds
    /// its tool table and clears calls from these, so its pinned prompt index
    /// matches what a local session would produce.
    tools: List(tool.Described),
    /// What the prompt needs, read once on the executor at attach. A local
    /// plane reads this lazily because probing helper health borrows a
    /// helper; a remote attach pays that cost once, beside the helpers.
    prompt: workspace_plane.PromptFacts,
    /// The executor broker's subject, for the orchestrator's non-tool callers
    /// (imported hooks, goal checks, Git observation). The orchestrator wraps
    /// it with `broker.over` and its own clock.
    broker: Subject(broker.Msg),
  )
}

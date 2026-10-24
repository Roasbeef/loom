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
import client/evolution/record
import client/executors
import client/system_prompt
import client/workspace_plane
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
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
    /// One entry for each MCP server the orchestrator expected this executor
    /// to run: whether it started, and why not when it did not. The
    /// orchestrator logs the refusals, which is where an operator learns that
    /// the executor's own `[mcp.<name>]` table is missing or its key unset.
    mcp: List(McpStatus),
    /// The branch the session's Git worktree has, `loom/<session id>`, for a
    /// session on a workspace in worktree mode and `None` otherwise
    /// (protocol-change/095). The session header shows it.
    branch: Option(String),
    /// Whether this executor can compile evolution candidates, and under which
    /// identity. The orchestrator opens the scope's catalogue with the identity
    /// (protocol-change/098), so evidence recorded against one executor's
    /// toolchain and seed never authorizes a build on another's.
    evolution: EvolutionCensus,
  )
}

/// What an executor says about compiling evolution candidates. It is computed
/// when the scope's plane is built, because the identity depends on the scope's
/// seed, and a rebound attach reuses it.
pub type EvolutionCensus {
  /// The executor compiles candidates, and `identity` is the toolchain, seed
  /// and evaluator fingerprint its builds carry.
  Compiles(identity: record.Identity)

  /// The executor cannot compile candidates, for a reason the operator can act
  /// on: no code-mode toolchain, or an evolution plane not built yet. A session
  /// on it has no evolution catalogue.
  Uncompiled(reason: String)
}

/// How one expected MCP server fared on the executor.
pub type McpStatus {
  /// The server started from the executor's own table and listed this many
  /// tools. Its module is in the executor's code mode.
  McpReady(server: String, tools: Int)

  /// The server did not start, for the reason given, which names no secret.
  McpRefused(server: String, reason: String)
}

/// The three facts a declaration makes claims about, read from a census: the
/// platform label, whether the helper enforces, and the toolchains the machine
/// provides (`codemode`, then each language server). The orchestrator compares
/// this with the executor's declaration at attach (`executors.contradiction`),
/// and the executor reports it of itself (`client/node_report`).
///
/// ## Examples
///
/// ```gleam
/// // remote_census.observed(remote).enforcement // -> executors.Enforced
/// ```
pub fn observed(remote: RemoteCensus) -> executors.Observed {
  let census = remote.census
  executors.Observed(
    platform: system_prompt.platform(census.platform),
    enforcement: case remote.prompt.helper {
      workspace_plane.Healthy -> executors.Enforced
      workspace_plane.Degraded -> executors.Degraded
    },
    toolchains: list.append(
      case census.toolchain {
        Ok(_found) -> ["codemode"]
        Error(_reason) -> []
      },
      list.map(census.lsp_servers, fn(server) { server.name }),
    ),
  )
}

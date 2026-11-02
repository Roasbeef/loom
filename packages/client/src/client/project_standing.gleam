//// What a session is to project mode, as a type every deciding site matches
//// on (`docs/design-notes/project-mode.md`, "The typed standing").
////
//// A catalogue row that marks a session becomes a hidden session kind when it
//// is consulted through scattered checks. The catalogue answers one question,
//// `catalogue.project_standing`, and this module lifts the answer into a
//// `Standing` with a case for each way a session can relate to a project. A
//// site that moves, sweeps, reopens, archives or changes the tools of a
//// session matches on `Standing` with no catch-all arm, so a further standing
//// fails to compile at every site that has to decide about it.
////
//// The type is named apart from `spawners.Standing` and
//// `session_directory.Standing`, which describe delegates and spawners. It
//// does not replace them and carries no delegate case.

import gleam/int
import gleam/option.{type Option, None, Some}
import storage/catalogue
import tools/project as project_tools

/// A session's part in project mode.
pub type Standing {
  /// The session belongs to no project and behaves as it always has.
  Ordinary

  /// The session is the router of a project.
  Router(
    /// The project's identity.
    project: String,
  )

  /// The session is the worker of one assignment of a ticket.
  Worker(
    /// The project's identity.
    project: String,
    /// The ticket.
    ticket: String,
    /// Which assignment of the ticket this session serves.
    seq: Int,
  )
}

/// A session's standing together with the tool seam it was built with, which
/// the session builder reads to shape the registry, the prompt and the model.
pub type Seat {
  Seat(
    /// What the session is to its project.
    standing: Standing,
    /// The host half of the project tools, filled for this session.
    seam: project_tools.Projects,
  )
}

/// How a session may be asked to leave its place.
pub type Mobility {
  /// The session may move or be archived as any other.
  Free

  /// The session holds a place for a live project, and the reason says so.
  Held(
    /// Worded for the person who asked.
    reason: String,
  )
}

/// Lifts the catalogue's answer.
///
/// ## Examples
///
/// ```gleam
/// assert project_standing.from_catalogue(catalogue.NotProject)
///   == project_standing.Ordinary
/// ```
pub fn from_catalogue(found: catalogue.ProjectStanding) -> Standing {
  case found {
    catalogue.NotProject -> Ordinary
    catalogue.RouterOf(project:) -> Router(project:)
    catalogue.WorkerOf(project:, ticket:, seq:) ->
      Worker(project:, ticket:, seq:)
  }
}

/// Whether the session may move or be archived while its project lives. A
/// router and a worker hold their places: the router is the project's
/// resident, and a worker's worktree and assignment are bound to this
/// machine.
///
/// ## Examples
///
/// ```gleam
/// assert project_standing.mobility(project_standing.Ordinary)
///   == project_standing.Free
/// ```
pub fn mobility(standing: Standing) -> Mobility {
  case standing {
    Ordinary -> Free
    Router(project:) ->
      Held("this session is the router of project " <> project)
    Worker(project:, ticket:, seq:) ->
      Held(
        "this session works ticket "
        <> ticket
        <> " (assignment "
        <> int.to_string(seq)
        <> ") of project "
        <> project,
      )
  }
}

/// The project a standing belongs to, or `None` for an ordinary session.
///
/// ## Examples
///
/// ```gleam
/// assert project_standing.project_of(project_standing.Router("p")) == Some("p")
/// ```
pub fn project_of(standing: Standing) -> Option(String) {
  case standing {
    Ordinary -> None
    Router(project:) | Worker(project:, ..) -> Some(project)
  }
}

/// The tools a session of this standing may never exceed, or `Ordinary` for no
/// ceiling. A router holds exactly the three router tools: no `code_mode`,
/// because `codemode/tool_gate` lets a capability with no matching tool
/// proceed, so a router that could start a program could reach anything.
///
/// ## Examples
///
/// ```gleam
/// assert project_standing.tool_ceiling(project_standing.Router("p"))
///   == Ok(["route", "project_read", "reply"])
/// ```
pub fn tool_ceiling(standing: Standing) -> Result(List(String), Nil) {
  case standing {
    Ordinary -> Error(Nil)
    Router(..) -> Ok(project_tools.router_tool_names)
    Worker(..) -> Error(Nil)
  }
}

/// The project tools a session of this standing is given in its registry.
///
/// ## Examples
///
/// ```gleam
/// assert project_standing.project_tool_names(project_standing.Ordinary) == []
/// ```
pub fn project_tool_names(standing: Standing) -> List(String) {
  case standing {
    Ordinary -> []
    Router(..) -> project_tools.router_tool_names
    Worker(..) -> project_tools.worker_tool_names
  }
}

/// Tools a worker is refused: the peer tools and the `agent_*` peers. A worker
/// talks to the project through its report and nothing else, so it gets no
/// door onto another session.
///
/// ## Examples
///
/// ```gleam
/// assert project_standing.worker_excludes("agent_spawn")
/// ```
pub fn worker_excludes(name: String) -> Bool {
  case name {
    "agent_" <> _ | "peer_" <> _ -> True
    _ -> False
  }
}

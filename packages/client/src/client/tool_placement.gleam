//// Which side of the workspace boundary runs each built-in tool.
////
//// A session has two halves, and a tool call runs on one of them. A tool that
//// reads or writes files, starts a process, drives a job or builds a program
//// acts on the checkout, so it runs beside it: this is the workspace side. A
//// tool that reads or changes the conversation (the Agency, recall, memory,
//// schedules, the context window, skills, peers, the advisor) needs the
//// owner's store and messaging plane, so it runs where those are: the owner
//// side.
////
//// On one machine the two sides share a VM and the distinction costs
//// nothing. It still has to be written down, because a workspace on another
//// node runs only what is placed on its side, and a tool nobody placed has no
//// defined home. This module is that decision as two lists of names, and
//// `client/serve` routes a call by it.
////
//// ## Extension tools are not placed
////
//// An extension's tool is whatever its manifest says, so no table compiled
//// into the harness can name it. `placement` answers `Error(Nil)` for a name
//// in neither list. A session whose workspace is in the owner's VM runs such a
//// tool on the owner, as it always has. A session whose workspace is on
//// another node refuses it, since running it on the owner would act on the
//// owner's machine and not on the workspace the model believes it is in.
////
//// ## The lists are checked, not trusted
////
//// `tool_placement_test` builds each half of the registry from the code that
//// builds it and asserts every name it produces is placed on the side it came
//// from, and that no name is on both. A tool added to a builder without a
//// line here fails that test, which is the point of keeping the table next to
//// nothing it could drift with.

import gleam/list
import tools/advise
import tools/agent
import tools/codemode as codemode_tool
import tools/context as context_tool
import tools/history as history_tool
import tools/job as job_tool
import tools/remember
import tools/schedule as schedule_tool

/// Which half of a session runs a tool.
pub type Placement {
  /// The tool acts on the checkout and runs beside it.
  WorkspaceSide

  /// The tool acts on the conversation and runs beside the store.
  OwnerSide
}

/// The five tools every host offers, which lead the registry. They are the
/// head of the workspace's list, and `contributions.compose` finds the first
/// cut by them.
pub const core_names = ["bash", "grep", "fs_read", "fs_write", "fs_edit"]

/// Every built-in tool that runs on the workspace side, in the order the
/// workspace registers them.
pub const workspace_names = [
  "bash", "grep", "fs_read", "fs_write", "fs_edit", codemode_tool.tool_name,
  job_tool.poll_tool_name, job_tool.kill_tool_name, job_tool.send_tool_name,
  "working_directory",
]

/// The agent family, as the owner registers it.
const agent_names = agent.tool_names

/// The tools which read or change the session's own state, other than the
/// agent family.
const session_names = [
  history_tool.tool_name, remember.tool_name, schedule_tool.create_tool_name,
  schedule_tool.list_tool_name, schedule_tool.cancel_tool_name,
  context_tool.tool_name, "load_skill", "peer_describe", "peer_roster",
  "peer_send", advise.name,
]

/// Every built-in tool that runs on the owner side.
pub fn owner_names() -> List(String) {
  list.append(agent_names, session_names)
}

/// Where a built-in tool runs, or `Error(Nil)` for a name which is not one
/// (an extension's tool).
///
/// ## Examples
///
/// ```gleam
/// assert tool_placement.placement("bash") == Ok(tool_placement.WorkspaceSide)
/// assert tool_placement.placement("agent_spawn") == Ok(tool_placement.OwnerSide)
/// assert tool_placement.placement("a_tool_from_an_extension") == Error(Nil)
/// ```
///
pub fn placement(name: String) -> Result(Placement, Nil) {
  case
    list.contains(workspace_names, name),
    list.contains(owner_names(), name)
  {
    True, False -> Ok(WorkspaceSide)
    False, True -> Ok(OwnerSide)
    True, True | False, False -> Error(Nil)
  }
}

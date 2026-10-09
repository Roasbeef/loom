//// Where each code-mode capability is answered when a session's workspace
//// is not in the same VM as its owner.
////
//// A code-mode program calls capabilities by name. Most of them act on the
//// checkout (`fs.*`, `proc.run`, `kv.*`, `job.*`, `lsp.*`, search) and can
//// only be answered beside it. A few touch state the session's owner holds:
//// the Agency behind `strand.*`, the blackboard behind `notes.*`, the
//// scheduling door, the MCP clients, the peer mailbox, the background
//// execution service and the durable cells an extension remembers into.
//// A workspace on another node routes the second group back to the owner
//// (`OwnerServices.capability`) and answers the first itself.
////
//// This module is that decision, written once as two lists of names. It is
//// built from the `serviced_caps` constants of the modules which answer
//// them rather than copied, so a name added to a router is a name this
//// module has to place: `cap_placement_test` walks every such list and
//// fails on a name which is in neither group or in both.
////
//// The classification follows where the state lives today. Background
//// execution (`execution.*`, `workflow.step`) keeps its record on the owner,
//// so a background program running beside the checkout reaches its own input
//// journal and progress channel back over the owner port. An `mcp.<server>`
//// name is the owner's here; a workspace that runs some servers itself
//// answers those names locally (`owner_codemode.over_owner_serving`).

import client/async_codemode
import client/codemode
import client/extension/seam as extension_seam
import client/peers
import client/workflows
import codemode/artifact
import codemode/lsp as codemode_lsp
import codemode/notes
import codemode/observation as codemode_observation
import codemode/orchestration
import codemode/search as search_router
import codemode/workspace
import gleam/list
import gleam/string

/// Which side of the workspace boundary answers a capability.
pub type Placement {
  /// The session's owner answers it, from state only the owner holds.
  OwnerBound

  /// The workspace answers it, beside the files it acts on.
  WorkspaceBound
}

// The three scheduling names live in the workspace seam's table because they
// share its closures, but the door they reach is the owner's.
const schedule_caps = [
  workspace.schedule_create_cap, workspace.schedule_list_cap,
  workspace.schedule_cancel_cap,
]

// The two extension names which write and read a durable session cell. The
// third (`net.request`) is a jailed network call and stays with the workspace.
const extension_owner_caps = [
  extension_seam.remember_cap,
  extension_seam.recall_cap,
]

/// The capability names the owner answers, other than the `mcp.<server>`
/// family, which `placement` recognises by prefix.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(cap_placement.owner_caps(), "strand.spawn")
/// ```
///
pub fn owner_caps() -> List(String) {
  // `report.emit` is in the orchestration table too, but it mints a blob
  // beside the checkout, so it is the workspace's.
  let orchestration_caps =
    list.filter(orchestration.serviced_caps, fn(cap) {
      cap != artifact.emit_cap
    })
  list.flatten([
    orchestration_caps,
    notes.serviced_caps,
    peers.serviced_caps,
    schedule_caps,
    async_codemode.serviced_caps,
    workflows.serviced_caps,
    extension_owner_caps,
  ])
  |> list.unique
}

/// The capability names the workspace answers.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(cap_placement.executor_caps(), "fs.read")
/// ```
///
pub fn executor_caps() -> List(String) {
  list.flatten([
    list.filter(workspace.serviced_caps, fn(cap) {
      !list.contains(schedule_caps, cap)
    }),
    search_router.serviced_caps,
    codemode_lsp.serviced_caps,
    [codemode_observation.snapshot_cap],
    codemode.serviced_caps,
    list.filter(extension_seam.serviced_caps, fn(cap) {
      !list.contains(extension_owner_caps, cap)
    }),
  ])
  |> list.unique
}

/// Where a capability is answered, or `Error(Nil)` for a name neither group
/// holds. An `mcp.<server>` name is the owner's, because the MCP clients and
/// the secrets they were started with stay on the owner.
///
/// ## Examples
///
/// ```gleam
/// assert cap_placement.placement("mcp.github") == Ok(cap_placement.OwnerBound)
/// assert cap_placement.placement("proc.run")
///   == Ok(cap_placement.WorkspaceBound)
/// assert cap_placement.placement("no.such") == Error(Nil)
/// ```
///
pub fn placement(cap: String) -> Result(Placement, Nil) {
  case
    string.starts_with(cap, "mcp.") || list.contains(owner_caps(), cap),
    list.contains(executor_caps(), cap)
  {
    True, False -> Ok(OwnerBound)
    False, True -> Ok(WorkspaceBound)
    True, True | False, False -> Error(Nil)
  }
}

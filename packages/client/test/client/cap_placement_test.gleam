//// Every code-mode capability has a side that answers it.
////
//// A router publishes the names it answers as a `serviced_caps` list. A name
//// added to any of them has to be placed by `client/cap_placement` before
//// this suite passes: on the owner or on the workspace, and never both,
//// because a name in neither is one a remote workspace would route nowhere
//// and a name in both is one it would answer twice.

import client/async_codemode
import client/cap_placement
import client/codemode
import client/extension/seam as extension_seam
import client/mcp as mcp_wiring
import client/peers
import client/workflows
import codemode/lsp as codemode_lsp
import codemode/notes
import codemode/observation as codemode_observation
import codemode/orchestration
import codemode/search as search_router
import codemode/workspace
import gleam/list

// Every list of names a router in the code-mode stack says it answers, and
// the one family built per host.
fn every_serviced_cap() -> List(String) {
  list.flatten([
    codemode.serviced_caps,
    orchestration.serviced_caps,
    notes.serviced_caps,
    workspace.serviced_caps,
    search_router.serviced_caps,
    codemode_lsp.serviced_caps,
    [codemode_observation.snapshot_cap],
    peers.serviced_caps,
    workflows.serviced_caps,
    async_codemode.serviced_caps,
    extension_seam.serviced_caps,
    mcp_wiring.serviced_caps(mcp_wiring.none()),
    ["mcp.github"],
  ])
}

pub fn every_serviced_capability_is_owner_bound_or_workspace_bound_test() {
  let unplaced =
    list.filter(every_serviced_cap(), fn(cap) {
      cap_placement.placement(cap) == Error(Nil)
    })
  assert unplaced == []
}

pub fn no_capability_is_in_both_groups_test() {
  let owner = cap_placement.owner_caps()
  let both =
    list.filter(cap_placement.executor_caps(), fn(cap) {
      list.contains(owner, cap)
    })
  assert both == []
}

pub fn the_groups_hold_only_names_some_router_answers_test() {
  // A stale name in a group would place a capability nothing serves, and the
  // exhaustiveness test above would never notice.
  let answered = every_serviced_cap()
  let stale =
    list.filter(
      list.append(cap_placement.owner_caps(), cap_placement.executor_caps()),
      fn(cap) { !list.contains(answered, cap) },
    )
  assert stale == []
}

pub fn the_state_a_capability_needs_decides_its_side_test() {
  // Owner state: the Agency, the blackboard, the scheduling door, the peer
  // mailbox, the MCP clients, and the durable cells an extension remembers.
  list.each(
    [
      "strand.spawn", "strand.roster", "notes.put", "schedule.create",
      "schedule.list", "schedule.cancel", "peer.send", "mcp.github",
      "ext.remember", "ext.recall", "execution.receive", "workflow.step",
    ],
    fn(cap) {
      assert cap_placement.placement(cap) == Ok(cap_placement.OwnerBound)
    },
  )

  // Checkout state: files, processes, scratch, jobs, language servers.
  list.each(
    [
      "fs.read", "fs.write", "kv.get", "job.start", "job.kill", "report.emit",
      "proc.run", "lsp.definition", "lsp.snapshot", "search.glob",
    ],
    fn(cap) {
      assert cap_placement.placement(cap) == Ok(cap_placement.WorkspaceBound)
    },
  )
}

pub fn an_unknown_name_has_no_side_test() {
  assert cap_placement.placement("no.such") == Error(Nil)
}

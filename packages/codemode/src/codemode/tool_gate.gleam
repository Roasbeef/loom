//// The strand's own tool list, applied to what its programs may do.
////
//// A strand's active tool list is how its parent controls it: withholding
//// `agent_send` keeps a reviewer child silent, withholding `agent_spawn` is
//// the depth cap, and withholding `bash` or `fs_write` makes a read-only
//// reviewer. The tool registry enforces that list for a model's own call.
//// A program's capability call never passes through the registry, so
//// without this module a strand could do from `code_mode` what its tool
//// list forbids it to do directly. This module is the one place that says
//// which tool authorizes which capability, and the one place that asks.
////
//// ## How a call is checked
////
//// Install: the host builds `precheck` from the Agency's `holds` closure
//// and the strand it serves, and hands it to the satellite host.
////
//// Per call: `precheck` → `required_tool` → `holds` → admitted or refused
////
//// 1. The satellite host admits a call, then its worker runs the precheck
////    before serving or clearing anything. The worker is the right place
////    because `holds` reads durable state, which the host actor must not
////    wait on.
//// 2. `required_tool` names the tool that does the same thing as the
////    capability, or says there is none and the call proceeds.
//// 3. `holds` answers on every call from the strand's durable
////    configuration, never from a snapshot, because a `set_config` can
////    withdraw a tool while a program is blocked. Only a tool genuinely
////    absent is refused as `tool_not_held`, in the sentence "<cap> needs
////    <tool>, which this strand does not hold". Any other refusal (a
////    holder that is down, an unreadable store) keeps its own code and
////    still stops the call.
////
//// ## What is deliberately open
////
//// A capability that reads state a strand could already see, or that has no
//// tool behind it, stays open: `fs.read`, `fs.list`, `search.*`, the
//// `lsp.*` queries (but not `lsp.rename`, which writes files), `kv.*`,
//// `report.emit`, the `peer.*` reads, the `execution.*` capabilities and
//// `mcp.<server>` (`open_caps` is the list, and `decided` is the question
//// a test asks of every router's published capabilities).
////
//// The `execution.*` capabilities are the running execution's own mailbox
//// and progress channel to the run that owns it. They reach no other
//// strand and no resource a tool guards.
////
//// MCP is open for now because an MCP server is already an operator's
//// per-server decision, made in configuration and bounded by its own
//// allowlist, and no strand tool corresponds to it; gating it would need a
//// per-server tool name the registry does not have.
////
//// Extensions are not strands. An extension satellite is reached through
//// its own registered tool, which the strand's list already gates, and the
//// long-lived host it runs on takes no precheck at all: it serves no
//// strand and asks no tool question.

import codemode/identity
import codemode/orchestration
import codemode/satellite.{type CapDenial, type CapRequest, CapDenial}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/agent.{type Caller, type Refusal}

/// The tool that authorizes each capability, or `None` for one no tool
/// stands behind.
///
/// One table for every family, so the question has one answer. Each row is
/// the tool that does the same thing for a model:
///
/// - `strand.*` is the matching `agent_*` tool.
/// - `proc.run` and `job.start` are `bash`, which runs a command and, in
///   its background mode, starts a job. The remaining job capabilities are
///   the job tools: `job_poll` reads a job and, with no id, lists them, so
///   `job.poll` and `job.list` both need it, `job.send` needs `job_send`
///   and `job.kill` needs `job_kill`.
/// - `fs.write` and `fs.edit` are `fs_write` and `fs_edit`.
/// - `schedule.*` is the matching `schedule_*` tool.
/// - `notes.put` writes the same blackboard cell `agent_note` writes,
///   through the same Agency closure, so it needs `agent_note`. The three
///   `notes` reads see the same cells `agent_notes` reads, so they need it.
/// - `lsp.rename` lands edits to files, which is what `fs_edit` does.
/// - `workflow.step` mints a child strand, which is what `agent_spawn`
///   does.
/// - `peer.send` is `peer_send`.
///
/// The match is on string literals because Gleam patterns cannot name a
/// constant; `tool_gate_test` walks the owning modules' `serviced_caps` to
/// keep this table and those lists from drifting.
///
/// ## Examples
///
/// ```gleam
/// // tool_gate.required_tool("fs.write") == Some("fs_write")
/// // tool_gate.required_tool("fs.read") == None
/// ```
///
pub fn required_tool(cap: String) -> Option(String) {
  case cap {
    "strand.spawn" -> Some("agent_spawn")
    "strand.wait" -> Some("agent_wait")
    "strand.send" -> Some("agent_send")
    "strand.note" -> Some("agent_note")
    "strand.notes" -> Some("agent_notes")
    "strand.roster" -> Some("agent_roster")
    "proc.run" -> Some("bash")
    "job.start" -> Some("bash")
    "job.poll" -> Some("job_poll")
    "job.list" -> Some("job_poll")
    "job.send" -> Some("job_send")
    "job.kill" -> Some("job_kill")
    "fs.write" -> Some("fs_write")
    "fs.edit" -> Some("fs_edit")
    "schedule.create" -> Some("schedule_create")
    "schedule.list" -> Some("schedule_list")
    "schedule.cancel" -> Some("schedule_cancel")
    "notes.put" -> Some("agent_note")
    "notes.get" -> Some("agent_notes")
    "notes.list" -> Some("agent_notes")
    "notes.read" -> Some("agent_notes")
    "lsp.rename" -> Some("fs_edit")
    "workflow.step" -> Some("agent_spawn")
    "peer.send" -> Some("peer_send")
    _ -> None
  }
}

/// The capabilities deliberately left open: reads of state a strand could
/// already see, and facilities no tool stands behind. See the module doc.
///
/// `mcp.<server>` is open too but is not listed, because its names are
/// configured at boot rather than known here; `decided` treats the prefix
/// as open.
pub const open_caps = [
  "fs.read", "fs.list", "kv.get", "kv.set", "kv.delete", "report.emit",
  "search.glob", "search.grep", "search.stat", "search.read_lines",
  "lsp.definition", "lsp.references", "lsp.hover", "lsp.outline", "lsp.calls",
  "lsp.diagnostics", "lsp.snapshot", "peer.roster", "peer.inbox",
  "peer.inbox_get", "peer.history", "peer.received", "peer.received_get",
  "peer.sent_receipt", "execution.receive", "execution.ready",
  "execution.receive_enveloped", "execution.progress", "execution.delivery",
]

/// Whether someone decided what this capability needs: it has a row in
/// `required_tool`, is listed in `open_caps`, or is an `mcp.` capability.
/// A capability that is none of these was added to a router without
/// anyone asking whether a tool should guard it, which is what the
/// classification tests fail on.
///
/// ## Examples
///
/// ```gleam
/// // tool_gate.decided("fs.write") == True
/// // tool_gate.decided("fs.delete") == False
/// ```
///
pub fn decided(cap: String) -> Bool {
  case required_tool(cap) {
    Some(_) -> True
    None -> list.contains(open_caps, cap) || string.starts_with(cap, "mcp.")
  }
}

/// The precheck for one strand's execution.
///
/// `holds` is the Agency's closure and `strand` and `source_index` are the
/// dispatching `Ctx`'s, never anything the program says. The `Caller` it
/// builds exists only to carry the strand to `holds`.
///
/// ## Examples
///
/// ```gleam
/// // satellite.SatelliteConfig(..config, precheck: tool_gate.precheck(agency.holds, "main", 0))
/// ```
///
pub fn precheck(
  holds: fn(Caller, String) -> Result(Nil, Refusal),
  strand: String,
  source_index: Int,
) -> satellite.Precheck {
  fn(request: CapRequest) {
    case required_tool(request.cap) {
      None -> Ok(Nil)
      Some(tool) ->
        holds(caller_of(request, strand, source_index), tool)
        |> result.map_error(denial(request.cap, _))
    }
  }
}

// A refusal as the in-band denial a program reads. A missing tool gets the
// message that names the capability and the tool; every other refusal is
// the Agency's own sentence under the code `orchestration.refusal_code`
// gives it, so a transient fault reads as one and the vocabulary has one
// owner.
fn denial(cap: String, refusal: Refusal) -> CapDenial {
  case refusal {
    agent.ToolNotHeld(tool:) ->
      CapDenial(
        code: orchestration.refusal_code(refusal),
        message: cap <> " needs " <> tool <> ", which this strand does not hold",
      )
    other ->
      CapDenial(
        code: orchestration.refusal_code(other),
        message: agent.describe(other),
      )
  }
}

fn caller_of(request: CapRequest, strand: String, source_index: Int) -> Caller {
  agent.Caller(
    strand:,
    operation: identity.op_id(request.identity),
    step_id: identity.step_id(request.identity),
    source_index:,
    minter: agent.Program(ordinal: request.ordinal),
  )
}

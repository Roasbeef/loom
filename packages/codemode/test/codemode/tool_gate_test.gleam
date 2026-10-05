//// The strand's tool list as a gate on its programs' capabilities: which
//// tool authorizes which capability, what a refusal says, and which
//// capabilities stay open.
////
//// These drive `tool_gate.precheck` directly against a scripted `holds`,
//// because what is worth proving here is the table and the refusal's
//// shape. That the host runs the precheck in the worker, before any plan,
//// is `satellite_test`'s; that the live Agency answers `holds` from a
//// strand's durable configuration is `client/agency_test`'s and
//// `client/codemode_test`'s.

import broker/budget
import broker/exec
import broker/policy
import codemode/identity
import codemode/notes
import codemode/orchestration
import codemode/satellite
import codemode/tool_gate
import core/clock
import core/ids
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tools/agent

const t = 1_700_000_000_000

fn request(cap: String) -> satellite.CapRequest {
  let generator = ids.generator(clock.fixed(at: t), seed: 23)
  let #(op, _generator) = ids.mint_op(generator)
  satellite.CapRequest(
    cap:,
    args: msgpack.MapValue([]),
    identity: identity.run_phase(identity.for_execution(
      op_id: op,
      step_id: "turn-1:tools",
      budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 60_000),
    )),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [],
    cwd: "/work",
    ordinal: 0,
  )
}

// Every capability the gate maps, with its tool: the table written out a
// second time, so a changed row has to be changed here too.
fn gated() -> List(#(String, String)) {
  [
    #("strand.spawn", "agent_spawn"),
    #("strand.wait", "agent_wait"),
    #("strand.send", "agent_send"),
    #("strand.note", "agent_note"),
    #("strand.notes", "agent_notes"),
    #("strand.roster", "agent_roster"),
    #("proc.run", "bash"),
    #("job.start", "bash"),
    #("job.poll", "job_poll"),
    #("job.list", "job_poll"),
    #("job.send", "job_send"),
    #("job.kill", "job_kill"),
    #("fs.write", "fs_write"),
    #("fs.edit", "fs_edit"),
    #("schedule.create", "schedule_create"),
    #("schedule.list", "schedule_list"),
    #("schedule.cancel", "schedule_cancel"),
    #("notes.put", "agent_note"),
  ]
}

// The capabilities left open on purpose.
fn open() -> List(String) {
  [
    "fs.read", "fs.list", "kv.get", "kv.set", "kv.delete", "report.emit",
    "notes.get", "notes.list", "notes.read", "search.glob", "search.grep",
    "search.stat", "search.read_lines", "lsp.definition", "lsp.references",
    "lsp.hover", "lsp.outline", "lsp.calls", "lsp.diagnostics", "lsp.rename",
    "lsp.snapshot",
  ]
}

// A strand that holds exactly `tools`.
fn holding(
  tools: List(String),
) -> fn(agent.Caller, String) -> Result(Nil, agent.Refusal) {
  fn(_caller, tool) {
    case list.contains(tools, tool) {
      True -> Ok(Nil)
      False -> Error(agent.ToolNotHeld(tool:))
    }
  }
}

pub fn the_table_is_the_one_written_out_here_test() {
  list.each(gated(), fn(pair) {
    assert tool_gate.required_tool(pair.0) == Some(pair.1)
  })
  list.each(open(), fn(cap) {
    assert tool_gate.required_tool(cap) == None
  })
}

pub fn every_serviced_capability_is_decided_test() {
  // A capability added to a router with no row here is a decision nobody
  // made, so this walks every list the routers publish and demands each be
  // either gated or deliberately open.
  let serviced =
    list.flatten([
      orchestration.serviced_caps,
      notes.serviced_caps,
      ["proc.run", "fs.read", "fs.list", "fs.write", "fs.edit", "kv.get"],
      ["kv.set", "kv.delete", "schedule.create", "schedule.list"],
      ["schedule.cancel", "job.start", "job.poll", "job.list", "job.kill"],
      ["job.send", "report.emit"],
    ])
  list.each(serviced, fn(cap) {
    let decided =
      list.key_find(gated(), cap) != Error(Nil) || list.contains(open(), cap)
    assert decided
  })
}

pub fn a_gated_capability_is_refused_without_its_tool_test() {
  list.each(gated(), fn(pair) {
    let #(cap, tool) = pair
    let check = tool_gate.precheck(holding([]), "main", 0)
    let assert Error(denial) = check(request(cap))
      as { cap <> " must be refused without " <> tool }
    assert denial.code == "tool_not_held"
    assert denial.message
      == cap <> " needs " <> tool <> ", which this strand does not hold"
  })
}

pub fn a_gated_capability_is_admitted_with_its_tool_test() {
  list.each(gated(), fn(pair) {
    let #(cap, tool) = pair
    let check = tool_gate.precheck(holding([tool]), "main", 0)
    assert check(request(cap)) == Ok(Nil)
  })
}

pub fn an_open_capability_is_admitted_with_no_tools_test() {
  let check = tool_gate.precheck(holding([]), "main", 0)
  list.each(open(), fn(cap) {
    assert check(request(cap)) == Ok(Nil)
  })
}

pub fn an_unknown_capability_is_not_this_gates_to_refuse_test() {
  // `mcp.<server>`, `peer.*` and the rest have no row, so the gate passes
  // them and each router decides for itself.
  let check = tool_gate.precheck(holding([]), "main", 0)
  assert check(request("mcp.docs")) == Ok(Nil)
}

pub fn a_fault_is_not_reported_as_a_missing_tool_test() {
  // A holder that is down is "try again", under its own code, and the call
  // still does not proceed.
  let check =
    tool_gate.precheck(
      fn(_caller, _tool) { Error(agent.AgencyUnavailable) },
      "main",
      0,
    )
  let assert Error(denial) = check(request("fs.write"))
    as "a fault must stop the call"
  assert denial.code == "strands_unavailable"
  assert !string.contains(denial.message, "does not hold")
}

pub fn the_question_is_asked_every_call_as_the_dispatching_strand_test() {
  // One grant is queued: the first call consumes it and the second is
  // refused, so nothing remembered the first answer. The strand asked
  // about is the one the host bound, never anything in the request.
  let grants = process.new_subject()
  let asked = process.new_subject()
  process.send(grants, Nil)
  let check =
    tool_gate.precheck(
      fn(caller: agent.Caller, tool) {
        process.send(asked, caller.strand)
        case process.receive(grants, 0) {
          Ok(Nil) -> Ok(Nil)
          Error(Nil) -> Error(agent.ToolNotHeld(tool:))
        }
      },
      "sub:main/reviewer-1",
      3,
    )
  assert check(request("fs.write")) == Ok(Nil)
  let assert Error(denial) = check(request("fs.write"))
    as "the second call must be refused"
  assert denial.code == "tool_not_held"
  assert process.receive(asked, 0) == Ok("sub:main/reviewer-1")
}

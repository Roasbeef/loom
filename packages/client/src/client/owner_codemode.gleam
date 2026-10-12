//// Code mode when a session's workspace and its owner are on different nodes.
////
//// A code-mode program runs beside the checkout, in a jailed satellite whose
//// capability socket is on the workspace's machine. Most of what it calls is
//// answered there: `fs.*`, `proc.run`, `kv.*`, `job.*`, `lsp.*` and search.
//// A few capabilities act on state which only the session's owner holds, and
//// `client/cap_placement` names them: `strand.*` needs the Agency and the
//// lineage ledger, `notes.*` the blackboard in the session store,
//// `schedule.*` the scheduling plane, `peer.*` the peer mailbox. This module
//// is both ends of that route.
////
//// ## The workspace sends
////
//// `over_owner` configures an executor's code mode. It offers the surface a
//// local session offers, both seams with their imports and advertised
//// capabilities, and it puts one router outside the execution's own: a call
//// whose name `cap_placement` gives to the owner is not routed here but sent
//// as an `OwnerCapCall` through `OwnerServices.capability`, and whatever the
//// owner answers is what the program reads. A call to any other name falls
//// through to the execution's router unchanged.
////
//// The surface needs an Agency to be built, and the executor has none. It is
//// given a stand-in whose every operation answers `AgencyUnavailable`, except
//// the tool-list check, which asks the owner. Nothing reaches the stand-in,
//// because the router above it takes every name the Agency would have
//// answered, and a bug which let a call through would be refused instead of
//// answered from nothing.
////
//// ## The owner answers
////
//// `answering` is the other end. It composes the arms a local session
//// composes into its router (`codemode.owner_answering`) from the session's
//// own Agency, scheduling door and peer wiring, so the owner answers a remote
//// program from the doors a local program would have been given. The session
//// it answers for is the session whose owner port received the message: the
//// record is built per session, and the call names no session.
////
//// ## What is the same, and what is not
////
//// The capability set, the tool-list check (`holds`) and every refusal come
//// from the same code a local session runs, so a remote program is neither
//// offered nor allowed more than a local one. Two things differ:
////
//// - An MCP server is answered where it runs. `mcp.<server>` is sent to the
////   owner unless the server started on the executor from the executor's own
////   table (`over_owner_serving`), in which case the executor answers it.
//// - An owner which serves only one seam refuses calls under the other, even
////   though the executor offers both, because the executor is not told which
////   seams the operator chose.
////
//// ## A background program's calls
////
//// A program launched in the background on the executor carries the step
//// `async/<id>` on every owner-bound call: the executor's tool shell set it
//// from the execution's record, never from the program. `answering_executions`
//// binds such a call to that execution. It reads the record, and answers only
//// while the record is starting or running and its strand and operation are
//// the call's. It then composes the arms a local background program is given:
//// the Agency's `async_seam` over the execution's custody, the workflow router
//// with the launching caller the record stores, and the execution's own input
//// and progress router. A call whose record has closed is refused with
//// `execution_closed`, and one naming an execution with no record with
//// `execution_unknown`.
////
//// ## When the owner cannot be reached
////
//// `OwnerServices.capability` is a monitored call. A dead owner port or a
//// dropped connection answers at once with the denial `owner_unavailable`,
//// and silence ends at the call's budget with the same denial. The exception
//// is a background program's `execution.*` calls, which `remote/owner_link`
//// lets wait out a dropped connection because each may be sent twice. The send
//// happens in the worker that serves the call, bounded by the execution's
//// call timeout, so a program waiting on an unreachable owner reads a denial
//// and the capability host goes on reading its channel.

import broker/framing.{type CapOutcome}
import client/agency
import client/async_codemode
import client/async_runs
import client/cap_placement
import client/codemode.{type Config, type OwnerSide}
import client/mcp as mcp_wiring
import client/owner_services.{type OwnerCapCall, type OwnerServices}
import client/peers
import client/remote/protocol
import codemode/satellite.{type CapDenial, type CapRouter}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/async_execution
import tools/agent
import tools/codemode as codemode_tool
import weft/registry as address

/// Configures a workspace's code mode for an owner on another node.
///
/// The surface is the shipped default of both seams, which is what a local
/// session offers unless the operator narrowed it. The tool-list check is the
/// owner's, so a program is held to its strand's tools as a local one is.
/// Peer capabilities are advertised by `advertising_peers`, applied to the
/// finished tool.
///
/// ## Examples
///
/// ```gleam
/// // codemode.default_config(broker:, clock:, workspace:, toolchain:)
/// // |> owner_codemode.over_owner(spec.owner)
/// ```
///
pub fn over_owner(config: Config, owner: OwnerServices) -> Config {
  over_owner_serving(config, owner, answered_here: [])
}

/// `over_owner` on a workspace that runs some MCP servers itself.
///
/// `answered_here` names the servers that started on this node from its own
/// configuration. A call to `mcp.<name>` for one of them stays with the
/// execution's router, whose MCP arm holds the client; any other `mcp.<name>`
/// is sent to the owner, as every owner-bound name is.
///
/// ## Examples
///
/// ```gleam
/// // owner_codemode.over_owner_serving(config, owner, answered_here: ["files"])
/// ```
///
pub fn over_owner_serving(
  config: Config,
  owner: OwnerServices,
  answered_here answered_here: List(String),
) -> Config {
  let inner = config.wrap_router
  let served =
    codemode.serving(config, codemode.BothSeams, over: stand_in(owner))
  codemode.Config(..served, wrap_router: fn(request, router) {
    sent_to(owner, answered_here, request, inner(request, router))
  })
}

// The Agency of a workspace whose owner is elsewhere. The one operation which
// is a question rather than an act, whether a strand holds a tool, goes to the
// owner. The rest are what the owner's own router answers, so they refuse.
fn stand_in(owner: OwnerServices) -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(agent.AgencyUnavailable) },
    send: fn(_caller, _to, _text, _within_ms) { Error(agent.AgencyUnavailable) },
    wait: fn(_caller, _handles, _within_ms) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    todos: fn(_caller, _step) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 0,
    model_names: [],
    holds: owner.holds,
  )
}

// The router outside the execution's: a name the owner answers is sent, and
// every other name is the execution's own. A denial from the owner, or from an
// owner that cannot be reached, travels to the program as the in-band error a
// router's refusal would have been.
fn sent_to(
  owner: OwnerServices,
  answered_here: List(String),
  request: codemode_tool.Request,
  inner: CapRouter,
) -> CapRouter {
  let capability = owner.capability
  fn(call: satellite.CapRequest) {
    case placed(call.cap, answered_here) {
      Ok(cap_placement.OwnerBound) ->
        Ok(
          satellite.ServedHere(fn() {
            case capability(call_for(request, call)) {
              Ok(outcome) -> outcome
              Error(denial) -> framing.CapErr(denial.code, denial.message)
            }
          }),
        )

      Ok(cap_placement.WorkspaceBound) | Error(Nil) -> inner(call)
    }
  }
}

// Where a capability is answered from this node: an MCP server this node runs
// itself is the workspace's, and everything else is as `cap_placement` says.
fn placed(
  cap: String,
  answered_here: List(String),
) -> Result(cap_placement.Placement, Nil) {
  case string.starts_with(cap, mcp_wiring.cap_prefix) {
    True ->
      case
        list.contains(
          answered_here,
          string.drop_start(cap, string.length(mcp_wiring.cap_prefix)),
        )
      {
        True -> Ok(cap_placement.WorkspaceBound)
        False -> Ok(cap_placement.OwnerBound)
      }
    False -> cap_placement.placement(cap)
  }
}

// The plain data the owner is sent. The strand, operation and step are the
// dispatching tool call's, filled in by the tool shell and never read from
// the program's arguments, so a program cannot name the strand it acts as.
fn call_for(
  request: codemode_tool.Request,
  call: satellite.CapRequest,
) -> OwnerCapCall {
  owner_services.OwnerCapCall(
    strand: request.strand,
    op_id: request.op_id,
    step_id: request.step_id,
    source_index: request.source_index,
    seam: codemode.vetting_seam(request.seam),
    cap: call.cap,
    args: call.args,
    ordinal: call.ordinal,
  )
}

/// Appends the peer capabilities to what every seam of a tool advertises.
///
/// The peer mailbox is composed around a local session's router by the
/// session, not by the code-mode configuration, so the seam built from the
/// configuration does not list its names. A session which serves them says so
/// here, once, for every seam it offers.
///
/// ## Examples
///
/// ```gleam
/// // codemode.seam(config) |> owner_codemode.advertising_peers
/// ```
///
pub fn advertising_peers(
  mode: codemode_tool.CodeMode,
) -> codemode_tool.CodeMode {
  let with_peers = fn(offer: codemode_tool.SeamOffer) {
    codemode_tool.SeamOffer(
      ..offer,
      serviced_caps: list.append(offer.serviced_caps, peers.serviced_caps),
    )
  }
  codemode_tool.CodeMode(
    ..mode,
    seams: codemode_tool.Seams(
      default: with_peers(mode.seams.default),
      alternates: list.map(mode.seams.alternates, with_peers),
    ),
  )
}

/// The owner's answer to a remote program's capability call: the arms of a
/// local session over `side`, with the session's peer mailbox outside them.
///
/// ## Examples
///
/// ```gleam
/// // owner_codemode.answering(
/// //   codemode.owner_serving(seams, over: agency_seam, schedules: door),
/// //   peers: peer_wiring,
/// // )
/// ```
///
pub fn answering(
  side: OwnerSide,
  peers wiring: peers.Wiring,
) -> fn(OwnerCapCall) -> Result(CapOutcome, CapDenial) {
  codemode.owner_answering(side, beyond: fn(strand, router) {
    peers.router(wiring, strand, router)
  })
}

/// What the owner needs to answer a background program's calls: the session's
/// execution service and Agency, the session runtime the records are read
/// from, and how to build the owner's side over an Agency bound to one
/// execution's custody.
pub type Background {
  Background(
    /// The session's execution service.
    service: address.Address(async_runs.Message),
    /// The Agency configuration a custody-bound Agency is built from.
    agents: agency.Config,
    /// The session runtime, which holds the execution records.
    runtime: fn() -> Result(api.Runtime, Nil),
    /// The owner's side over a given Agency: the seams the operator chose, the
    /// scheduling door and the MCP layer, as for a foreground call.
    side_over: fn(agent.Agency) -> OwnerSide,
  )
}

/// The owner's answer to a remote program's capability call, for foreground
/// and background programs alike.
///
/// A call whose step is not an execution's is answered by `answering` over
/// `foreground`. A call whose step is `async/<id>` is bound to that execution
/// as the module doc describes, and refused when its record does not allow it.
///
/// ## Examples
///
/// ```gleam
/// // owner_codemode.answering_executions(side, peers: wiring, background:)
/// ```
pub fn answering_executions(
  foreground: OwnerSide,
  peers wiring: peers.Wiring,
  background background: Background,
) -> fn(OwnerCapCall) -> Result(CapOutcome, CapDenial) {
  let answer_foreground = answering(foreground, peers: wiring)
  fn(call: OwnerCapCall) {
    case
      string.starts_with(call.step_id, protocol.execution_step_prefix),
      execution_of(call)
    {
      False, _ -> answer_foreground(call)
      True, id -> answer_background(background, wiring, call, id)
    }
  }
}

fn execution_of(call: OwnerCapCall) -> String {
  string.drop_start(call.step_id, string.length(protocol.execution_step_prefix))
}

// One call of a background program, bound to its record. The record is read
// on every call, because a cancel, an abort or the deadline can close it while
// the program runs on, and a closed execution must not spawn, read input or
// write a note.
fn answer_background(
  background: Background,
  wiring: peers.Wiring,
  call: OwnerCapCall,
  id: String,
) -> Result(CapOutcome, CapDenial) {
  use launching <- result.try(bound(background, call, id))
  let custody = api.AsyncCustody(call.strand, call.op_id, id, api.Owned)
  let side = background.side_over(agency.async_seam(background.agents, custody))
  let service = background.service
  let agents = background.agents
  codemode.owner_answering(side, beyond: fn(strand, router) {
    peers.router(wiring, strand, router)
    |> async_codemode.execution_routers(service, agents, custody, launching, _)
  })(call)
}

// The execution a background call belongs to, when it may still be answered:
// the record exists, it is the call's strand's and operation's, it is starting
// or running, and it names the call that launched it. A record an earlier build
// wrote has no launching call, and the owner cannot attribute a workflow step
// without one.
fn bound(
  background: Background,
  call: OwnerCapCall,
  id: String,
) -> Result(async_codemode.Launching, CapDenial) {
  let read = {
    use live <- result.try(
      background.runtime()
      |> result.replace_error("the session runtime is not available"),
    )
    async_runs.record(live, id)
  }
  case read {
    Error(reason) -> Error(unknown_execution(reason))
    Ok(None) -> Error(unknown_execution("there is no such execution"))
    Ok(Some(record)) -> bound_to(record, call, id)
  }
}

fn bound_to(
  record: async_execution.Execution,
  call: OwnerCapCall,
  id: String,
) -> Result(async_codemode.Launching, CapDenial) {
  let ours = record.strand == call.strand && record.operation == call.op_id
  let open = case record.phase {
    async_execution.Starting | async_execution.Running -> True
    async_execution.Draining
    | async_execution.Finished(_)
    | async_execution.Lost(_) -> False
  }
  case ours, open, record.launch {
    False, _, _ -> Error(unknown_execution("the execution is not this call's"))
    True, False, _ ->
      Error(satellite.CapDenial(
        code: execution_closed_code,
        message: "the background execution "
          <> id
          <> " has closed, so its program can no longer reach the session",
      ))
    True, True, None ->
      Error(unknown_execution(
        "the execution's record does not name the call that launched it",
      ))
    True, True, Some(launch) ->
      Ok(async_codemode.Launching(
        id:,
        strand: record.strand,
        operation: record.operation,
        step: launch.step,
        source_index: launch.source_index,
      ))
  }
}

fn unknown_execution(reason: String) -> CapDenial {
  satellite.CapDenial(code: execution_unknown_code, message: reason)
}

/// The denial code of a call from a background program whose record has
/// closed.
pub const execution_closed_code = "execution_closed"

/// The denial code of a call that names a background execution the owner
/// cannot bind it to.
pub const execution_unknown_code = "execution_unknown"

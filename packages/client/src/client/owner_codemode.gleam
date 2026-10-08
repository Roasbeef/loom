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
//// offered nor allowed more than a local one. Three things differ, all of
//// them omissions:
////
//// - MCP façades are not offered on an executor, so `mcp.*` has no caller.
//// - Background code mode and workflow steps are not offered, and the owner
////   refuses a call to one by name.
//// - An owner which serves only one seam refuses calls under the other, even
////   though the executor offers both, because the executor is not told which
////   seams the operator chose.
////
//// ## When the owner cannot be reached
////
//// `OwnerServices.capability` is a monitored call. A dead owner port or a
//// dropped connection answers at once with the denial `owner_unavailable`,
//// and silence ends at the call's budget with the same denial. The send
//// happens in the worker that serves the call, bounded by the execution's
//// call timeout, so a program waiting on an unreachable owner reads a denial
//// and the capability host goes on reading its channel.

import broker/framing.{type CapOutcome}
import client/cap_placement
import client/codemode.{type Config, type OwnerSide}
import client/owner_services.{type OwnerCapCall, type OwnerServices}
import client/peers
import codemode/satellite.{type CapDenial, type CapRouter}
import gleam/list
import tools/agent
import tools/codemode as codemode_tool

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
  let inner = config.wrap_router
  let served =
    codemode.serving(config, codemode.BothSeams, over: stand_in(owner))
  codemode.Config(..served, wrap_router: fn(request, router) {
    sent_to(owner, request, inner(request, router))
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
  request: codemode_tool.Request,
  inner: CapRouter,
) -> CapRouter {
  let capability = owner.capability
  fn(call: satellite.CapRequest) {
    case cap_placement.placement(call.cap) {
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

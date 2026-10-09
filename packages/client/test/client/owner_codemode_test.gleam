//// Code mode on a workspace whose owner is on another node: the executor
//// sends owner-bound capability calls as plain data and the owner answers
//// them from the session's own doors.
////
//// Every test drives the capability router the satellite is given
//// (`codemode.exec_config`), so what is exercised is what a running program
//// reaches, not a function beside it. The owner side is a real owner port
//// over a real `OwnerServices`, and the executor side reaches it through a
//// real `owner_link`, so a call crosses the same message boundary it crosses
//// between two nodes. Only the transport differs: both ends are in one VM,
//// and `daemon_shipped_remote_caps_test` runs the same route across two
//// daemons.

import broker/broker
import broker/exec
import broker/framing.{type CapOutcome}
import broker/policy
import client/codemode
import client/owner_codemode
import client/owner_services.{type OwnerCapCall, type OwnerServices}
import client/peer_mail
import client/peers
import client/remote/owner_link
import client/remote/owner_port
import client/remote/protocol as remote_protocol
import codemode/identity
import codemode/orchestration
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import support/remote_fixtures as fixtures
import tools/agent
import tools/codemode as codemode_tool
import tools/directory_access
import tools/tool

@external(erlang, "client_test_ffi", "function_values")
fn function_values(term: a) -> Int

// --- fixtures ----------------------------------------------------------------

fn idle_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: fn(bytes) { <<0:size(bytes)-unit(8)>> },
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  started
}

fn config_for(broker_actor: broker.Broker) -> codemode.Config {
  codemode.default_config(
    broker: broker_actor,
    clock: clock.fixed(at: 1000),
    workspace: "/work",
    toolchain: codemode.toolchain(
      gleam_path: "/opt/gleam/bin/gleam",
      erl_path: "/usr/lib/erlang/bin/erl",
      seed_root: "/opt/loom/codemode-seed",
    ),
  )
}

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn request_on(seam: codemode_tool.Seam) -> codemode_tool.Request {
  codemode_tool.Request(
    directory_access: directory_access.none(),
    source: "pub fn main() { todo }",
    seam:,
    strand: "main",
    op_id: an_op(3),
    step_id: "turn-1:tools",
    source_index: 2,
    workspace: "/work",
    base_policy: policy.workspace_default("/work"),
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    within_ms: 60_000,
    grants: [],
    observe_output: tool.ignore_output(),
  )
}

fn string(text: String) -> msgpack.MsgPackValue {
  msgpack.StringValue(text)
}

fn spawn_args() -> msgpack.MsgPackValue {
  msgpack.MapValue([
    pair("purpose", string("review")),
    pair("brief", string("read the diff")),
    pair("context", string("fresh")),
    pair("detach", msgpack.BoolValue(False)),
  ])
}

fn pair(
  key: String,
  value: msgpack.MsgPackValue,
) -> #(msgpack.MsgPackValue, msgpack.MsgPackValue) {
  #(string(key), value)
}

// The capability router a satellite is given for one execution, called as the
// satellite's host calls it: the plan is run here, as its worker would.
fn routed(
  config: codemode.Config,
  seam: codemode_tool.Seam,
  cap: String,
  args: msgpack.MsgPackValue,
) -> CapOutcome {
  let request = request_on(seam)
  let pipeline =
    codemode.exec_config(
      config,
      request,
      "/work/notes",
      9_000_000,
      widened_by: [],
    )
  let cap_request =
    satellite.CapRequest(
      cap:,
      args:,
      identity: identity.run_phase(pipeline.identity),
      base_policy: request.base_policy,
      demand: request.demand,
      env: [],
      cwd: request.workspace,
      ordinal: 4,
    )
  // The satellite's host asks the strand's tool list before it routes.
  let planned = case pipeline.satellite.precheck(cap_request) {
    Ok(Nil) -> pipeline.satellite.router(cap_request)
    Error(denial) -> Error(denial)
  }
  case planned {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(satellite.ServedHere(serve)) | Ok(satellite.ScopedService(serve)) ->
      serve()
    Ok(satellite.ClearedCall(..)) ->
      panic as "these calls are serviced by the host"
  }
}

// What the owner's Agency saw: one line per operation, naming the strand it
// was asked on behalf of.
pub fn agency_over(seen: Subject(String)) -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(agent.AgencyUnavailable) },
    send: fn(_caller, _to, _text, _within_ms) { Error(agent.AgencyUnavailable) },
    wait: fn(_caller, _handles, _within_ms) { Error(agent.AgencyUnavailable) },
    note: fn(caller: agent.Caller, key, _value) {
      process.send(seen, "note " <> caller.strand <> " " <> key)
      Ok(Nil)
    },
    notes: fn(caller: agent.Caller, _prefix) {
      process.send(seen, "notes " <> caller.strand)
      Ok([])
    },
    todos: fn(_caller, _step) { Error(agent.AgencyUnavailable) },
    roster: fn(caller: agent.Caller) {
      process.send(seen, "roster " <> caller.strand)
      Ok([])
    },
    max_wait_ms: 30_000,
    model_names: [],
    holds: fn(_caller, _tool) { Ok(Nil) },
  )
}

// Owner services whose strand holds every tool, so the per-call check passes.
fn permissive() -> OwnerServices {
  owner_services.OwnerServices(
    ..fixtures.quiet_services(),
    holds: fn(_caller, _tool) { Ok(Nil) },
  )
}

// The session's peer mailbox: every command is recorded and answered with an
// empty list, which is what a strand with no links is told.
pub fn mailbox(seen: Subject(String)) -> peers.Wiring {
  peers.Wiring(
    own: peer_mail.Endpoint(session: "owner-session", call: fn(command) {
      case command {
        peer_mail.Links(source_strand:) -> {
          process.send(seen, "links " <> source_strand)
          Ok(json.Array([]))
        }
        _ -> Error(peer_mail.Refused("unexpected peer command"))
      }
    }),
    metadata: json.Null,
    directory: None,
  )
}

// The owner of a remote session, as `client/serve` builds it: the Agency and
// the mailbox of this session answering through the arms a local session uses.
fn owner_over(
  seams: codemode.Seams,
  agency: agent.Agency,
  wiring: peers.Wiring,
) -> OwnerServices {
  owner_services.OwnerServices(
    ..fixtures.quiet_services(),
    capability: owner_codemode.answering(
      codemode.owner_serving(seams, over: agency, schedules: None),
      peers: wiring,
    ),
    holds: agency.holds,
  )
}

// A port serving `services`, and the executor-side `OwnerServices` which reach
// it through a link. The port is returned so a test can end it.
fn linked(
  services: OwnerServices,
) -> #(owner_port.Port, owner_link.Link, OwnerServices) {
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services:,
      clock: clock.fixed(at: 5000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: remote_protocol.McpPlan(served: [], expected: []),
    ))
    as "the owner port starts"
  let assert Ok(link) = owner_link.start(owner_port.inbox(port))
    as "the link starts"
  #(port, link, owner_link.services(link, clock.fixed(at: 5000)))
}

// The executor's code-mode configuration over a given owner.
fn executor_over(
  broker_actor: broker.Broker,
  owner: OwnerServices,
) -> codemode.Config {
  owner_codemode.over_owner(config_for(broker_actor), owner)
}

// A local session's configuration over the same Agency, mailbox and seams,
// built as `client/serve` builds one.
fn local_over(
  broker_actor: broker.Broker,
  agency: agent.Agency,
  wiring: peers.Wiring,
) -> codemode.Config {
  let config =
    config_for(broker_actor)
    |> codemode.serving(codemode.BothSeams, over: agency)
  codemode.Config(
    ..config,
    wrap_router: fn(request: codemode_tool.Request, router) {
      peers.router(wiring, request.strand, router)
    },
  )
}

// --- the surface ---------------------------------------------------------------

pub fn the_executor_offers_what_a_local_session_offers_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()
  let agency = agency_over(seen)
  let local =
    local_over(broker_actor, agency, mailbox(seen))
    |> codemode.seam
    |> owner_codemode.advertising_peers
  let remote =
    executor_over(
      broker_actor,
      owner_over(codemode.BothSeams, agency, mailbox(seen)),
    )
    |> codemode.seam
    |> owner_codemode.advertising_peers

  // Imports, advertised capabilities and generated surfaces, for both seams.
  // A remote program is neither offered nor refused anything a local one is
  // not, MCP aside, and no MCP server is configured here.
  assert remote.seams == local.seams
  assert list.contains(remote.seams.default.serviced_caps, "peer.roster")
  assert list.contains(remote.seams.default.serviced_caps, "strand.spawn")
  broker.stop(broker_actor)
}

// --- a call crosses as plain data --------------------------------------------------

pub fn an_owner_bound_call_leaves_the_executor_as_plain_data_test() {
  let broker_actor = idle_broker()
  let sent = process.new_subject()
  let owner =
    owner_services.OwnerServices(
      ..permissive(),
      capability: fn(call: OwnerCapCall) {
        process.send(sent, call)
        Ok(framing.CapOk(string("owner said so")))
      },
    )
  let config = executor_over(broker_actor, owner)

  let outcome =
    routed(
      config,
      codemode_tool.OrchestrationSeam,
      "notes.put",
      msgpack.MapValue([pair("key", string("k")), pair("value", string("v"))]),
    )
  assert outcome == framing.CapOk(string("owner said so"))

  // The dispatching call's coordinates, the seam, and the capability's own
  // name, arguments and ordinal. The strand is the request's, as the tool
  // shell filled it in, and nothing the program supplied.
  let assert Ok(call) = process.receive(sent, 100)
  let request = request_on(codemode_tool.OrchestrationSeam)
  assert call
    == owner_services.OwnerCapCall(
      strand: "main",
      op_id: request.op_id,
      step_id: "turn-1:tools",
      source_index: 2,
      seam: vet_policy.OrchestrationSeam,
      cap: "notes.put",
      args: msgpack.MapValue([
        pair("key", string("k")),
        pair("value", string("v")),
      ]),
      ordinal: 4,
    )

  // It holds no function, process or reference: it would mean the same on any
  // node.
  assert function_values(call) == 0
  broker.stop(broker_actor)
}

pub fn every_owner_bound_name_is_sent_and_nothing_else_is_test() {
  let broker_actor = idle_broker()
  let sent = process.new_subject()
  let owner =
    owner_services.OwnerServices(
      ..permissive(),
      capability: fn(call: OwnerCapCall) {
        process.send(sent, call.cap)
        Ok(framing.CapOk(msgpack.NilValue))
      },
    )
  let config = executor_over(broker_actor, owner)

  // One name from each owner-bound family.
  let owned = [
    "strand.roster", "strand.note", "notes.list", "schedule.list", "peer.roster",
    "execution.ready",
  ]
  list.each(owned, fn(cap) {
    let _ =
      routed(config, codemode_tool.WorkspaceSeam, cap, msgpack.MapValue([]))
    assert process.receive(sent, 100) == Ok(cap)
  })

  // A workspace-bound name is answered beside the checkout. The scratch store
  // is absent in this fixture, so the answer is its own in-band refusal, and
  // the owner is not asked.
  let outcome =
    routed(
      config,
      codemode_tool.WorkspaceSeam,
      "kv.get",
      msgpack.MapValue([pair("key", string("k"))]),
    )
  let assert framing.CapErr(code: "kv_unavailable", ..) = outcome
  assert process.receive(sent, 50) == Error(Nil)
  broker.stop(broker_actor)
}

// --- the owner answers ---------------------------------------------------------------

pub fn the_owner_answers_a_remote_program_as_it_answers_a_local_one_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()
  let agency = agency_over(seen)
  let wiring = mailbox(seen)
  let #(port, link, services) =
    linked(owner_over(codemode.BothSeams, agency, wiring))
  let remote = executor_over(broker_actor, services)
  let local = local_over(broker_actor, agency, wiring)

  // The same calls, on both seams, through the wire and without it. Each
  // answer is the one the local router gives, including the refusals.
  list.each(
    [
      #("strand.roster", msgpack.MapValue([])),
      #("strand.note", msgpack.MapValue([pair("key", string("k"))])),
      #("strand.spawn", spawn_args()),
      #("notes.list", msgpack.MapValue([pair("prefix", string(""))])),
      #(
        "notes.put",
        msgpack.MapValue([pair("key", string("k")), pair("value", string("v"))]),
      ),
      #("notes.put", msgpack.MapValue([])),
      #("peer.roster", msgpack.MapValue([])),
    ],
    fn(call) {
      let #(cap, args) = call
      list.each(
        [codemode_tool.WorkspaceSeam, codemode_tool.OrchestrationSeam],
        fn(seam) {
          assert routed(remote, seam, cap, args)
            == routed(local, seam, cap, args)
        },
      )
    },
  )

  // And the owner's Agency and mailbox were the ones asked, for the strand
  // the dispatching call named.
  let asked = drain(seen, [])
  assert list.contains(asked, "roster main")
  assert list.contains(asked, "note main k")
  assert list.contains(asked, "notes main")
  assert list.contains(asked, "links main")
  owner_link.stop(link)
  owner_port.stop(port)
  broker.stop(broker_actor)
}

fn drain(seen: Subject(String), found: List(String)) -> List(String) {
  case process.receive(seen, 20) {
    Ok(line) -> drain(seen, [line, ..found])
    Error(Nil) -> found
  }
}

pub fn a_remote_note_lands_on_the_owner_for_the_calling_strand_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()
  let #(port, link, services) =
    linked(owner_over(codemode.BothSeams, agency_over(seen), mailbox(seen)))
  let remote = executor_over(broker_actor, services)

  let outcome =
    routed(
      remote,
      codemode_tool.WorkspaceSeam,
      "notes.put",
      msgpack.MapValue([pair("key", string("k")), pair("value", string("v"))]),
    )
  let assert framing.CapOk(_) = outcome
  assert process.receive(seen, 100) == Ok("note main k")
  owner_link.stop(link)
  owner_port.stop(port)
  broker.stop(broker_actor)
}

// --- the owner refuses -----------------------------------------------------------------

pub fn the_owners_denial_reaches_the_program_unchanged_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()
  let #(port, link, services) =
    linked(owner_over(codemode.BothSeams, agency_over(seen), mailbox(seen)))
  let remote = executor_over(broker_actor, services)

  // Background code mode is the owner's by placement and not served for a
  // remote workspace, so the owner names the refusal and the program reads it.
  let assert framing.CapErr(code: "unsupported_cap", message:) =
    routed(
      remote,
      codemode_tool.WorkspaceSeam,
      "execution.ready",
      msgpack.MapValue([]),
    )
  assert message == "`execution.ready` is not answered by the session owner"

  // The Agency's own refusal is the answer too, as it is locally.
  let assert framing.CapErr(code: "strands_unavailable", ..) =
    routed(
      remote,
      codemode_tool.OrchestrationSeam,
      "strand.spawn",
      spawn_args(),
    )
  owner_link.stop(link)
  owner_port.stop(port)
  broker.stop(broker_actor)
}

pub fn an_owner_serving_one_seam_refuses_the_other_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()

  // The operator chose the workspace seam alone. The executor, which is not
  // told, still offers both, and the owner holds the line.
  let #(port, link, services) =
    linked(owner_over(codemode.WorkspaceOnly, agency_over(seen), mailbox(seen)))
  let remote = executor_over(broker_actor, services)
  let assert framing.CapErr(code: "unsupported_cap", message:) =
    routed(
      remote,
      codemode_tool.OrchestrationSeam,
      "notes.list",
      msgpack.MapValue([pair("prefix", string(""))]),
    )
  assert message == "the session owner does not serve the orchestration seam"
  assert drain(seen, []) == []

  // The same call under the seam it does serve is answered, and `strand.*`
  // is not routed at all on a workspace-only surface.
  let assert framing.CapOk(_) =
    routed(
      remote,
      codemode_tool.WorkspaceSeam,
      "notes.list",
      msgpack.MapValue([pair("prefix", string(""))]),
    )
  let assert framing.CapErr(code: "unsupported_cap", ..) =
    routed(
      remote,
      codemode_tool.WorkspaceSeam,
      "strand.roster",
      msgpack.MapValue([]),
    )
  owner_link.stop(link)
  owner_port.stop(port)
  broker.stop(broker_actor)
}

pub fn the_tool_list_check_is_the_owners_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()
  let agency =
    agent.Agency(..agency_over(seen), holds: fn(_caller, name) {
      Error(agent.ToolNotHeld(tool: name))
    })
  let #(port, link, services) =
    linked(owner_over(codemode.BothSeams, agency, mailbox(seen)))
  let remote = executor_over(broker_actor, services)

  // A strand which does not hold `fs_write` cannot read through a program: the
  // check the satellite makes per call is answered by the owner, which is
  // where the strand's tool list lives.
  let assert framing.CapErr(code:, message:) =
    routed(
      remote,
      codemode_tool.WorkspaceSeam,
      "fs.write",
      msgpack.MapValue([
        pair("path", string("a.txt")),
        pair("content", string("x")),
      ]),
    )
  assert code == orchestration.refusal_code(agent.ToolNotHeld(tool: "fs_write"))
  assert message == "fs.write needs fs_write, which this strand does not hold"
  owner_link.stop(link)
  owner_port.stop(port)
  broker.stop(broker_actor)
}

// --- the link is down ------------------------------------------------------------------

pub fn a_call_with_the_owner_gone_is_denied_at_once_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()
  let #(port, link, services) =
    linked(owner_over(codemode.BothSeams, agency_over(seen), mailbox(seen)))
  let remote = executor_over(broker_actor, services)
  let assert Ok(port_pid) = process.subject_owner(owner_port.inbox(port))
  process.unlink(port_pid)
  process.kill(port_pid)
  assert fixtures.eventually(fn() { !process.is_alive(port_pid) })

  // The call itself: a monitored request answers with the denial the moment
  // the port is seen to be gone, and does not wait out its two-minute budget.
  let call = fixtures.capability_call()
  let denied = process.new_subject()
  let _ =
    process.spawn(fn() { process.send(denied, services.capability(call)) })
  let assert Ok(Error(denial)) = process.receive(denied, 5000)
    as "a call to a gone owner must answer, not wait out its budget"
  assert denial.code == owner_link.unavailable_code

  // And through the router a program reaches. The tool-list check is the
  // owner's too, so with the owner gone it is the check which refuses first,
  // and the program reads a refusal either way. What it never reads is
  // silence.
  let answered = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        answered,
        routed(
          remote,
          codemode_tool.OrchestrationSeam,
          "strand.roster",
          msgpack.MapValue([]),
        ),
      )
    })
  let assert Ok(framing.CapErr(..)) = process.receive(answered, 5000)
    as "a program's call to a gone owner must be refused, not hang"
  owner_link.stop(link)
  broker.stop(broker_actor)
}

pub fn an_mcp_server_the_executor_runs_is_answered_beside_the_checkout_test() {
  let broker_actor = idle_broker()
  let sent = process.new_subject()
  let owner =
    owner_services.OwnerServices(
      ..permissive(),
      capability: fn(call: OwnerCapCall) {
        process.send(sent, call.cap)
        Ok(framing.CapOk(msgpack.NilValue))
      },
    )
  let config =
    owner_codemode.over_owner_serving(
      config_for(broker_actor),
      owner,
      answered_here: [
        "files",
      ],
    )
  let call = msgpack.MapValue([pair("tool", string("read"))])

  // A server the orchestrator runs is the owner's, so its call is sent.
  let _ = routed(config, codemode_tool.WorkspaceSeam, "mcp.github", call)
  assert process.receive(sent, 100) == Ok("mcp.github")

  // A server this executor started from its own table is answered here: the
  // owner is not asked. This fixture's layer holds no client for it, so the
  // answer is the local router's own refusal.
  let outcome = routed(config, codemode_tool.WorkspaceSeam, "mcp.files", call)
  let assert framing.CapErr(code: "unsupported_cap", ..) = outcome
  assert process.receive(sent, 50) == Error(Nil)
  broker.stop(broker_actor)
}

//// A host-defined code-mode seam (protocol-change/110), through the code the
//// production paths run: `client/codemode`'s vetting, description and router
//// for a local session, and `codemode.owner_answering` for an owner whose
//// workspace is on an executor.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/codemode
import client/host_seam
import client/owner_services
import codemode/identity
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/ids.{type OpId}
import core/json
import core/message
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/host_fixtures
import tools/agent
import tools/codemode as codemode_tool
import tools/directory_access
import tools/fs
import tools/tool

// --- a host to vet against ----------------------------------------------------

// A broker that is never asked for a helper: vetting refuses, or the absent
// toolchain stops the pipeline, before one would be.
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

// A host serving both seams over an Agency, under aegis's seam.
fn hosted(broker_actor: broker.Broker, holds: Holds) -> codemode.Config {
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
  |> codemode.serving(codemode.BothSeams, over: agency(holds))
  |> codemode.over_host(Some(host_fixtures.layer()))
}

type Holds {
  HoldsEverything
  HoldsNothing
}

fn agency(holds: Holds) -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(agent.AgencyUnavailable) },
    wait: fn(_caller, _handles, _within) { Error(agent.AgencyUnavailable) },
    send: fn(_caller, _to, _text, _within_ms) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    todos: fn(_caller, _step) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Ok([]) },
    max_wait_ms: 30_000,
    model_names: [],
    orchestrator_names: [],
    holds: fn(_caller, tool) {
      case holds {
        HoldsEverything -> Ok(Nil)
        HoldsNothing -> Error(agent.ToolNotHeld(tool:))
      }
    },
  )
}

fn an_op() -> OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  op
}

fn request(source: String) -> codemode_tool.Request {
  codemode_tool.Request(
    directory_access: directory_access.none(),
    source:,
    seam: codemode_tool.WorkspaceSeam,
    strand: "main",
    op_id: an_op(),
    step_id: "turn-1:tools",
    source_index: 0,
    workspace: "/work",
    base_policy: policy.workspace_default("/work"),
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    within_ms: 60_000,
    grants: [],
    observe_output: tool.ignore_output(),
  )
}

fn refused_imports(result: codemode_tool.ExecResult) -> List(String) {
  case result {
    codemode_tool.VetRejected(rejections:) ->
      list.filter_map(rejections, fn(rejection) {
        case rejection.rule {
          codemode_tool.ImportNotAllowed -> Ok(rejection.detail)
          codemode_tool.NoForeignInterface | codemode_tool.Unparseable ->
            Error(Nil)
        }
      })
    codemode_tool.CompileFailed(..)
    | codemode_tool.RunFailed(..)
    | codemode_tool.Ran(..) -> []
  }
}

// --- vetting --------------------------------------------------------------------

pub fn a_program_importing_a_module_the_host_refused_is_refused_at_vet_test() {
  let broker_actor = idle_broker()
  let config = hosted(broker_actor, HoldsEverything)

  // Every module aegis refuses, one program each, refused at vetting by name.
  list.each(
    [
      "cap/fs", "cap/proc", "cap/net", "cap/git", "cap/peer", "cap/actor",
      "cap/schedule", "cap/job", "cap/strand", "cap/workflow",
    ],
    fn(module) {
      let source =
        "import " <> module <> "\nimport cap/report\npub fn main() { 1 }\n"
      let refused =
        refused_imports(codemode.execute(config, request(source)).result)
      assert list.any(refused, string.contains(_, module))
    },
  )

  // Under the orchestration seam too: the host narrows both selections.
  let orchestrating =
    codemode_tool.Request(
      ..request("import cap/strand\npub fn main() { 1 }\n"),
      seam: codemode_tool.OrchestrationSeam,
    )
  assert refused_imports(codemode.execute(config, orchestrating).result) != []
  broker.stop(broker_actor)
}

pub fn a_program_importing_the_admitted_modules_passes_vetting_test() {
  let broker_actor = idle_broker()
  let config = hosted(broker_actor, HoldsEverything)
  let source =
    "import cap/aegis\nimport cap/kv\nimport cap/mcp\nimport cap/report\n"
    <> "import cap/search\nimport cap/task\npub fn main() { 1 }\n"

  // Vetting passes; the absent toolchain is what stops it afterwards.
  assert refused_imports(codemode.execute(config, request(source)).result) == []
  broker.stop(broker_actor)
}

pub fn a_host_seam_never_widens_a_seam_test() {
  // `cap/lsp` is on aegis's list, but this host wired no language server, so
  // the import stays refused: a host narrows what the doors admit and cannot
  // admit a module whose door is absent.
  let broker_actor = idle_broker()
  let config = hosted(broker_actor, HoldsEverything)
  let source = "import cap/lsp\npub fn main() { 1 }\n"
  let refused =
    refused_imports(codemode.execute(config, request(source)).result)
  assert list.any(refused, string.contains(_, "cap/lsp"))
  broker.stop(broker_actor)
}

// --- the description ------------------------------------------------------------

pub fn the_description_carries_the_host_module_and_drops_what_it_refuses_test() {
  let broker_actor = idle_broker()
  let offer = codemode.seam(hosted(broker_actor, HoldsEverything)).seams.default

  assert list.contains(offer.allowed_imports, "cap/aegis")
  assert list.contains(offer.allowed_imports, "cap/search")
  assert !list.contains(offer.allowed_imports, "cap/fs")
  assert !list.contains(offer.allowed_imports, "cap/strand")
  assert list.contains(offer.serviced_caps, "host.aegis")
  assert list.contains(offer.serviced_caps, "search.grep")
  assert !list.contains(offer.serviced_caps, "proc.run")
  assert !list.contains(offer.serviced_caps, "strand.spawn")
  assert !list.contains(offer.serviced_caps, "fs.write")

  // The generated types are in the description the model reads.
  let assert [surface] =
    list.filter(offer.extra_surfaces, string.starts_with(_, "### cap/aegis"))
    as "one surface for the host module"
  assert string.contains(surface, "pub fn file_finding(")
  assert string.contains(surface, "pub fn read_notes(")
  assert string.contains(surface, "FileFindingResult")
  broker.stop(broker_actor)
}

pub fn the_generated_module_calls_the_host_family_test() {
  let assert [#(module, source)] = host_seam.generated(host_fixtures.layer())
    as "one generated module"
  assert module == "cap/aegis"
  assert string.contains(source, "internal.host_invoke_typed(")
  assert string.contains(source, "\"aegis\"")
  assert !string.contains(source, "internal.invoke(")
}

// --- declarations the host gets wrong -------------------------------------------

pub fn a_seam_naming_an_unknown_module_is_refused_test() {
  let seam = host_seam.HostSeam(..host_fixtures.seam(), imports: ["cap/serach"])
  let assert Error(reason) = host_seam.build(seam) as "a misspelt module"
  assert string.contains(reason, "cap/serach")
}

pub fn a_host_module_cannot_shadow_a_shipped_module_test() {
  list.each(["fs", "mcp", "internal", "strand"], fn(name) {
    let seam =
      host_seam.HostSeam(
        ..host_fixtures.seam(),
        module: Some(host_seam.HostModule(name:, functions: [])),
      )
    let assert Error(reason) = host_seam.build(seam) as "a shipped name"
    assert string.contains(reason, "ships")
  })
  let seam =
    host_seam.HostSeam(
      ..host_fixtures.seam(),
      module: Some(host_seam.HostModule(name: "Aegis/x", functions: [])),
    )
  let assert Error(_) = host_seam.build(seam) as "not an identifier"
}

pub fn a_host_module_offering_one_tool_twice_is_refused_test() {
  let twice =
    host_seam.HostFunction(tool: host_fixtures.read_notes(), output: None)
  let seam =
    host_seam.HostSeam(
      ..host_fixtures.seam(),
      module: Some(
        host_seam.HostModule(name: "aegis", functions: [twice, twice]),
      ),
    )
  let assert Error(reason) = host_seam.build(seam) as "a duplicate tool"
  assert string.contains(reason, "twice")
}

// --- the local router -----------------------------------------------------------

fn cap_request(cap: String, args: MsgPackValue, ordinal: Int) {
  satellite.CapRequest(
    cap:,
    args:,
    identity: identity.run_phase(identity.for_execution(
      op_id: an_op(),
      step_id: "turn-1:tools",
      budget: budget.Budget(max_outstanding: 6, deadline_ms: 9000),
    )),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [],
    cwd: "/work",
    ordinal:,
  )
}

fn host_args(tool: String, fields: List(#(String, String))) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("tool"), msgpack.StringValue(tool)),
    #(
      msgpack.StringValue("arguments"),
      msgpack.MapValue(
        list.map(fields, fn(pair) {
          #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
        }),
      ),
    ),
  ])
}

// Runs one call through a router and returns what the program would read.
fn served(
  router: satellite.CapRouter,
  call: satellite.CapRequest,
) -> Result(framing.CapOutcome, satellite.CapDenial) {
  case router(call) {
    Ok(satellite.ServedHere(serve)) | Ok(satellite.ScopedService(serve)) ->
      Ok(serve())
    Ok(satellite.ClearedCall(..)) ->
      Error(satellite.CapDenial(code: "cleared", message: "cleared"))
    Error(denial) -> Error(denial)
  }
}

fn local_router(holds: Holds) -> satellite.CapRouter {
  let built =
    codemode.exec_config(
      hosted(idle_broker(), holds),
      request("pub fn main() { 1 }\n"),
      "/work/x",
      9000,
      widened_by: [],
    )
  built.satellite.router
}

pub fn a_withheld_capability_is_refused_by_the_router_test() {
  let assert Error(denial) =
    served(
      local_router(HoldsEverything),
      cap_request("lsp.rename", msgpack.MapValue([]), 0),
    )
    as "lsp.rename is withheld"
  assert denial.code == host_seam.withheld_code
  assert string.contains(denial.message, "lsp.rename")
}

pub fn a_local_host_call_runs_the_hosts_own_tool_test() {
  let assert Ok(framing.CapOk(value)) =
    served(
      local_router(HoldsEverything),
      cap_request(
        "host.aegis",
        host_args("file_finding", [
          #("title", "refund"),
          #("stage", "hypotheses"),
        ]),
        0,
      ),
    )
    as "the host's tool answers"
  assert texts(value) == ["filed refund"]
  assert flag(value) == Ok(False)
  assert structured_id(value) == Ok(7)
}

// --- refusals look like the direct tool's ---------------------------------------

// What a model reads from a direct call: the tool's own outcome text.
fn direct(arguments: List(#(String, String))) -> #(List(String), Bool) {
  let outcome =
    host_fixtures.file_finding().run(
      any_ctx(),
      json.Object(
        list.map(arguments, fn(pair) { #(pair.0, json.String(pair.1)) }),
      ),
    )
  #(
    list.filter_map(outcome.content, fn(block) {
      case block {
        message.ToolResultText(text:, ..) -> Ok(text)
        message.ToolResultImage(..) -> Error(Nil)
      }
    }),
    outcome.is_error,
  )
}

// A context for a direct call; the fixture's tools read none of it.
fn any_ctx() -> tool.Ctx {
  tool.Ctx(
    workspace: "/work",
    strand: "main",
    op_id: an_op(),
    step_id: "turn-1:tools",
    source_index: 0,
    base_policy: policy.workspace_default("/work"),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: fs.real_filesystem(),
    blob_root: "",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

pub fn a_host_calls_refusal_looks_the_same_as_the_direct_tools_test() {
  let arguments = [#("title", "refund"), #("stage", "validation")]
  let #(direct_text, direct_failed) = direct(arguments)
  assert direct_failed
  assert direct_text == [host_fixtures.refusal]

  // Locally and on an owner: the same text, and failed, which
  // `cap/internal/mcp` reads as `ToolFailed(message)`.
  let call = cap_request("host.aegis", host_args("file_finding", arguments), 0)
  let assert Ok(framing.CapOk(local)) =
    served(local_router(HoldsEverything), call)
    as "a local host call answers"
  assert texts(local) == direct_text
  assert flag(local) == Ok(True)

  let assert Ok(framing.CapOk(owned)) =
    owner(HoldsEverything)(owner_call("host.aegis", call.args))
    as "an owner answers"
  assert texts(owned) == direct_text
  assert flag(owned) == Ok(True)
}

pub fn a_strand_without_the_tool_is_refused_before_it_runs_test() {
  let call =
    cap_request(
      "host.aegis",
      host_args("file_finding", [#("title", "x"), #("stage", "hypotheses")]),
      0,
    )
  let assert Ok(framing.CapErr(code:, message:)) =
    served(local_router(HoldsNothing), call)
    as "the tool-list check answers in band"
  assert code == "tool_not_held"
  assert string.contains(message, "file_finding")
  let assert Ok(framing.CapErr(code: owned, ..)) =
    owner(HoldsNothing)(owner_call("host.aegis", call.args))
    as "the owner asks the same question"
  assert owned == "tool_not_held"
}

// --- the owner holds the seam ---------------------------------------------------

fn owner(
  holds: Holds,
) -> fn(owner_services.OwnerCapCall) ->
  Result(framing.CapOutcome, satellite.CapDenial) {
  owner_over(codemode.BothSeams, holds)
}

// An owner serving `seams`, holding the host seam with the Agency's check, as
// `client/serve` builds one.
fn owner_over(
  seams: codemode.Seams,
  holds: Holds,
) -> fn(owner_services.OwnerCapCall) ->
  Result(framing.CapOutcome, satellite.CapDenial) {
  let agency = agency(holds)
  let side =
    codemode.OwnerSide(
      ..codemode.owner_serving(seams, over: agency, schedules: None),
      host: Some(codemode.OwnerHost(
        host_fixtures.layer(),
        clock.fixed(at: 0),
        Some(agency.holds),
      )),
    )
  codemode.owner_answering(side, beyond: fn(_strand, router) { router })
}

fn owner_call(cap: String, args: MsgPackValue) -> owner_services.OwnerCapCall {
  owner_services.OwnerCapCall(
    strand: "main",
    op_id: an_op(),
    step_id: "turn-1:tools",
    source_index: 0,
    seam: vet_policy.WorkspaceSeam,
    cap:,
    args:,
    ordinal: 0,
  )
}

pub fn a_workspace_only_owner_still_asks_for_the_tool_test() {
  // An owner that serves the workspace seam alone has no Agency on its
  // surface. The host call is still held to the strand's tools, as a local
  // session of the same choice is.
  let call =
    host_args("file_finding", [#("title", "x"), #("stage", "hypotheses")])
  let assert Ok(framing.CapErr(code:, ..)) =
    owner_over(codemode.WorkspaceOnly, HoldsNothing)(owner_call(
      "host.aegis",
      call,
    ))
    as "the tool-list check answers in band"
  assert code == "tool_not_held"
}

pub fn an_owner_refuses_what_the_hosts_seam_excludes_test() {
  // An executor that ignored the seam and sent these anyway: the owner
  // answers none of them, though its Agency would have.
  list.each(
    ["strand.roster", "strand.spawn", "notes.put", "lsp.rename"],
    fn(cap) {
      let assert Error(denial) =
        owner(HoldsEverything)(owner_call(cap, msgpack.MapValue([])))
        as "refused by the seam"
      assert denial.code == host_seam.withheld_code
    },
  )

  // A host module the session does not have is refused too.
  let assert Error(_other_host) =
    owner(HoldsEverything)(owner_call("host.other", host_args("read_notes", [])))
    as "another host module"

  // The host's own module is answered.
  let assert Ok(framing.CapOk(value)) =
    owner(HoldsEverything)(owner_call("host.aegis", host_args("read_notes", [])))
    as "read_notes answers"
  assert texts(value) == ["no notes yet"]
}

pub fn an_owner_without_a_host_seam_answers_as_before_test() {
  let side =
    codemode.owner_serving(
      codemode.BothSeams,
      over: agency(HoldsEverything),
      schedules: None,
    )
  let answer =
    codemode.owner_answering(side, beyond: fn(_strand, router) { router })
  let assert Ok(framing.CapOk(_roster)) =
    answer(owner_call("strand.roster", msgpack.MapValue([])))
    as "the roster is answered"
}

// --- reading results ------------------------------------------------------------

fn entry(value: MsgPackValue, key: String) -> Result(MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.key_find(entries, msgpack.StringValue(key))
    _other -> Error(Nil)
  }
}

fn texts(value: MsgPackValue) -> List(String) {
  case entry(value, "content") {
    Ok(msgpack.ArrayValue(items:)) ->
      list.filter_map(items, fn(item) {
        case entry(item, "text") {
          Ok(msgpack.StringValue(text)) -> Ok(text)
          _other -> Error(Nil)
        }
      })
    _other -> []
  }
}

fn flag(value: MsgPackValue) -> Result(Bool, Nil) {
  case entry(value, "is_error") {
    Ok(msgpack.BoolValue(flag)) -> Ok(flag)
    _other -> Error(Nil)
  }
}

fn structured_id(value: MsgPackValue) -> Result(Int, Nil) {
  case entry(value, "structured") {
    Ok(structured) ->
      case entry(structured, "id") {
        Ok(msgpack.IntValue(id)) -> Ok(id)
        _other -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

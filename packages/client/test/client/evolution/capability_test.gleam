//// The route from a program to the session's evolution doors: where the
//// module is admitted, advertised and routed, what a candidate can import,
//// and how the cell the configuration reaches the doors through behaves.
////
//// Nothing here runs a program. That the whole route works end to end,
//// from a scripted model through `code_mode` to the catalogue and back, is
//// `evolution_acceptance_test`'s, under `LOOM_EVOLUTION_E2E`.

import broker/broker
import broker/exec
import broker/framing
import broker/policy
import client/codemode
import client/evolution/capability
import client/evolution/model_door
import client/serve
import client/serve_test
import codemode/evolution as codemode_evolution
import codemode/identity
import codemode/satellite
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import tools/codemode as codemode_tool
import tools/directory_access
import tools/evolution as evolution_tool
import tools/fs
import tools/tool
import weft/registry as address

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

fn bare(broker_actor: broker.Broker) -> codemode.Config {
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

// A builder whose catalogue operation reports the coordinates it was bound
// to, so a test reads which execution a door was built for from its answer.
fn reporting(ctx: tool.Ctx) -> codemode_evolution.Door {
  let refuse = fn(_ordinal, _arguments) {
    Error("Authority: not wired in this test")
  }
  codemode_evolution.Door(
    propose: refuse,
    test_candidate: refuse,
    inspect: refuse,
    catalogue: fn(_ordinal, _arguments) {
      Ok(
        json.Object([
          #("strand", json.String(ctx.strand)),
          #("workspace", json.String(ctx.workspace)),
          #("step", json.String(ctx.step_id)),
          #("source_index", json.Int(ctx.source_index)),
        ]),
      )
    },
    invoke: refuse,
    trace: refuse,
  )
}

fn offered(broker_actor: broker.Broker) -> codemode.Config {
  codemode.over_evolution(bare(broker_actor), Some(reporting))
}

fn request_on(seam: codemode_tool.Seam) -> codemode_tool.Request {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  codemode_tool.Request(
    directory_access: directory_access.none(),
    source: "pub fn main() { todo }",
    seam:,
    strand: "sub:main/reviewer-1",
    op_id: op,
    step_id: "turn-9:tools",
    source_index: 4,
    workspace: "/work",
    base_policy: policy.workspace_default("/work"),
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    within_ms: 60_000,
    grants: [],
    observe_output: tool.ignore_output(),
  )
}

fn routed(
  config: codemode.Config,
  seam: codemode_tool.Seam,
  cap: String,
) -> framing.CapOutcome {
  let request = request_on(seam)
  let configured =
    codemode.exec_config(
      config,
      request,
      "/work/evolution",
      9_000_000,
      widened_by: [],
    )
  let cap_request =
    satellite.CapRequest(
      cap:,
      args: msgpack.MapValue([]),
      identity: identity.run_phase(configured.identity),
      base_policy: request.base_policy,
      demand: request.demand,
      env: [],
      cwd: request.workspace,
      ordinal: 0,
    )
  case configured.satellite.router(cap_request) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(satellite.ServedHere(serve)) | Ok(satellite.ScopedService(serve)) ->
      serve()
    Ok(satellite.ClearedCall(..)) ->
      panic as "an evolution call is served by the host"
  }
}

const importing = "import cap/evolution\npub fn main() { evolution.trace(1) }\n"

pub fn no_plane_hides_cap_evolution_from_code_mode_test() {
  let broker_actor = idle_broker()
  let base = bare(broker_actor)
  let allowlist = codemode.seam_allowlist(base, vet_policy.WorkspaceSeam)
  assert !vet_policy.contains(allowlist, "cap/evolution")
  assert !list.any(
    codemode.seam_caps_on(base, vet_policy.WorkspaceSeam),
    string.starts_with(_, "evolution."),
  )
  assert !string.contains(
    codemode_tool.description(codemode.seam(base)),
    "evolution",
  )
  let assert vet.Rejected([rejection]) = vet.vet(importing, allowlist)
  assert string.contains(string.inspect(rejection), "cap/evolution")
  let assert framing.CapErr(code: "unsupported_cap", ..) =
    routed(base, codemode_tool.WorkspaceSeam, "evolution.catalogue")
  broker.stop(broker_actor)
}

pub fn a_plane_admits_renders_advertises_and_routes_cap_evolution_test() {
  let broker_actor = idle_broker()
  let config = offered(broker_actor)
  let seam = vet_policy.WorkspaceSeam
  assert vet_policy.contains(
    codemode.seam_allowlist(config, seam),
    "cap/evolution",
  )
  assert list.all(codemode_evolution.serviced_caps, list.contains(
    codemode.seam_caps_on(config, seam),
    _,
  ))
  assert string.contains(
    codemode_tool.description(codemode.seam(config)),
    "### cap/evolution",
  )

  // With no direct tools, the description's one sentence is the discovery.
  assert string.contains(
    codemode_tool.description(codemode.seam(config)),
    "only reachable through `cap/evolution`",
  )
  let assert vet.Passed(_) =
    vet.vet(importing, codemode.seam_allowlist(config, seam))

  // The door was built for this execution's coordinates, which the program
  // never named.
  let assert framing.CapOk(msgpack.MapValue(fields)) =
    routed(config, codemode_tool.WorkspaceSeam, "evolution.catalogue")
  assert list.key_find(fields, msgpack.StringValue("strand"))
    == Ok(msgpack.StringValue("sub:main/reviewer-1"))
  assert list.key_find(fields, msgpack.StringValue("step"))
    == Ok(msgpack.StringValue("turn-9:tools"))
  assert list.key_find(fields, msgpack.StringValue("source_index"))
    == Ok(msgpack.IntValue(4))
  broker.stop(broker_actor)
}

pub fn only_the_workspace_seam_sees_the_plane_test() {
  let broker_actor = idle_broker()
  let config = offered(broker_actor)
  list.each(
    [
      vet_policy.OrchestrationSeam,
      vet_policy.ExtensionSeam,
      vet_policy.ResidentSeam,
    ],
    fn(seam) {
      assert !vet_policy.contains(
        codemode.seam_allowlist(config, seam),
        "cap/evolution",
      )
      assert !list.contains(
        codemode.seam_caps_on(config, seam),
        "evolution.invoke",
      )
    },
  )
  broker.stop(broker_actor)
}

// The load-bearing rule for candidates: whatever host a candidate is vetted
// and run under, `cap/evolution` is not on its allowlist, so a selected
// program cannot propose, test or invoke another candidate from inside its
// own run. The allowlist is what `evolution/identity` hashes, so the rule is
// part of a candidate's recorded identity.
pub fn a_candidate_importing_cap_evolution_is_refused_at_vetting_test() {
  let broker_actor = idle_broker()
  let candidate_host = codemode.without_evolution(offered(broker_actor))
  let allowlist =
    codemode.seam_allowlist(candidate_host, vet_policy.WorkspaceSeam)
  assert !vet_policy.contains(allowlist, "cap/evolution")
  let assert vet.Rejected([rejection]) = vet.vet(importing, allowlist)
  assert string.contains(string.inspect(rejection), "cap/evolution")

  // The extension seam, which vets every extension candidate, never admits
  // the module whatever the session has.
  let assert vet.Rejected([_]) =
    vet.vet(importing, vet_policy.for_seam(vet_policy.ExtensionSeam))

  // Withdrawing the door changes the allowlist and nothing else about the
  // host, so the identity hash moves only for hosts that offered it.
  assert codemode.seam_allowlist(candidate_host, vet_policy.WorkspaceSeam)
    == codemode.seam_allowlist(bare(broker_actor), vet_policy.WorkspaceSeam)
  broker.stop(broker_actor)
}

pub fn a_borrow_before_the_cell_starts_says_the_plane_is_not_open_test() {
  let assert Ok(registry) = address.start()
  let name = address.new_address(registry)
  assert capability.borrow(name)
    == Error("Unavailable: the evolution plane is not open")
  let assert Ok(Nil) = address.stop(registry)
}

pub fn a_started_cell_hands_out_the_door_until_it_is_stopped_test() {
  let assert Ok(registry) = address.start()
  let name = address.new_address(registry)
  let door = unwired()
  let assert Ok(cell) = capability.start(name, door)
  capability.detach(cell)
  let assert Ok(borrowed) = capability.borrow(name)
  assert borrowed.catalogue(ctx(), json.Null)
    == tool.success("catalogue answered")

  // The stop is queued ahead of the next borrow, so the borrow finds either
  // no registered name or a callee that went down, and never a stale door.
  capability.stop(name)
  assert capability.borrow(name)
    == Error("Unavailable: the evolution plane is not open")
  let assert Ok(Nil) = address.stop(registry)
}

pub fn the_cell_builder_runs_the_borrowed_door_under_the_callers_context_test() {
  let assert Ok(registry) = address.start()
  let name = address.new_address(registry)
  let builder = capability.door_over(name)
  let before = builder(ctx())
  assert before.catalogue(0, json.Null)
    == Error("Unavailable: the evolution plane is not open")
  let assert Ok(cell) = capability.start(name, unwired())
  capability.detach(cell)
  let after = builder(ctx())
  assert after.catalogue(0, json.Null) == Ok(json.String("catalogue answered"))
  assert after.propose(0, json.Null) == Error("Authority: propose refused")
  capability.stop(name)
  let assert Ok(Nil) = address.stop(registry)
}

// Two concurrent calls of one execution share its operation, so the source
// index is what keeps their scratch directories apart. Every slot and ordinal
// the host admits must map to its own index, none of which is a real tool
// call's position within a message.
pub fn every_admitted_call_of_an_execution_has_its_own_index_test() {
  let indexes =
    list.flat_map([0, 1, 2, 3, 4, 5], fn(slot) {
      list.index_map(list.repeat(Nil, 128), fn(_, ordinal) {
        capability.call_index(3, slot, ordinal)
      })
    })
  assert list.length(list.unique(indexes)) == 6 * 128

  // The clamp on the ordinal is sound only while no ceiling admits more than
  // 128 calls of one name.
  assert list.all(codemode_evolution.ceilings(), fn(ceiling) {
    ceiling.admissions <= 128
  })
  assert list.all(indexes, fn(index) { index >= 1000 })
  assert capability.call_index(2, 1, 3) == 3131
  assert capability.call_index(3, 0, 0) != capability.call_index(2, 0, 0)
}

pub fn an_operation_runs_its_door_under_the_calls_own_index_test() {
  let assert Ok(registry) = address.start()
  let name = address.new_address(registry)
  let seen = process.new_subject()
  let reporting =
    evolution_tool.Door(..unwired(), invoke: fn(ctx: tool.Ctx, _args) {
      process.send(seen, ctx.source_index)
      tool.success("{}")
    })
  let assert Ok(cell) = capability.start(name, reporting)
  capability.detach(cell)
  let door = capability.door_over(name)(ctx())
  let assert Ok(_) = door.invoke(5, json.Null)
  assert process.receive(seen, 100) == Ok(capability.call_index(0, 4, 5))
  capability.stop(name)
  let assert Ok(Nil) = address.stop(registry)
}

// `LOOM_DISABLE_TOOLS` has no tool left to filter, so one reserved name stands
// for the module. A trial is never offered it whatever the list says.
pub fn the_reserved_name_withholds_the_module_from_a_source_session_test() {
  let assert Ok(registry) = address.start()
  let name = address.new_address(registry)
  let settings = serve_test.settings_under("build/evolution-switch")
  let assert option.Some(_) = serve.evolution_offer(settings, name)
  let disabled =
    serve.Settings(..settings, deactivated_tools: [
      "bash",
      serve.evolution_switch,
    ])
  assert serve.evolution_offer(disabled, name) == option.None
  let trial = serve.Settings(..settings, evolution_role: serve.Trial([]))
  assert serve.evolution_offer(trial, name) == option.None
  let assert Ok(Nil) = address.stop(registry)
}

// `cap/evolution.compare` sends a task-set identity and all six budget
// fields, and the native decoder must accept exactly that map. The wire shape
// is pinned in the cap package; this ties it to the decoder without the
// end-to-end flag.
pub fn the_map_compare_sends_is_the_map_the_decoder_accepts_test() {
  let limits =
    json.Object([
      #("trials", json.Int(20)),
      #("turns", json.Int(20)),
      #("tokens", json.Int(1_000_000)),
      #("dollars", json.Float(2.0)),
      #("output_bytes", json.Int(65_536)),
      #("wall_ms", json.Int(120_000)),
    ])
  let arguments =
    json.Object([
      #("candidate_id", json.String("c1")),
      #("taskset_id", json.String("ts1")),
      #("limits", limits),
    ])
  let assert Ok(#("ts1", accepted)) = model_door.evaluation_request(arguments)
  assert accepted.trials == 20 && accepted.wall_ms == 120_000
}

pub fn a_doors_outcome_becomes_json_or_a_refusal_sentence_test() {
  assert capability.outcome(tool.failure("Stale: the generation moved"))
    == Error("Stale: the generation moved")
  assert capability.outcome(tool.success("{\"a\":1}"))
    == Ok(json.Object([#("a", json.Int(1))]))
  assert capability.outcome(tool.with_details(
      tool.success("ignored"),
      json.Int(7),
    ))
    == Ok(json.Int(7))
  assert capability.outcome(tool.success("not json"))
    == Ok(json.String("not json"))
}

fn unwired() -> evolution_tool.Door {
  let refused = fn(_ctx, _args) { tool.failure("Authority: propose refused") }
  evolution_tool.Door(
    propose: refused,
    test_candidate: refused,
    inspect: refused,
    catalogue: fn(_ctx, _args) { tool.success("catalogue answered") },
    invoke: refused,
    trace: refused,
  )
}

fn ctx() -> tool.Ctx {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5))
  tool.Ctx(
    workspace: "/work",
    strand: "main",
    op_id: op,
    step_id: "turn-1:tools",
    source_index: 0,
    base_policy: policy.workspace_default("/work"),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: fs.real_filesystem(),
    blob_root: "/work/.blobs",
    clear_call: fn(_spec, _events) { panic as "no jailed call in this test" },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

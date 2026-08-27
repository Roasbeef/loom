//// The code-mode wiring: what a request turns into before the pipeline
//// sees it.
////
//// Nothing here runs a program — that is `make e2e-codemode`'s job, and
//// it needs a toolchain, a prepared seed, and a kernel that can jail. What
//// these tests own is the part that is decided *before* any of that and
//// cannot be observed afterwards: the identity and the budget the two
//// jailed stages are dispatched under, the one dimension of the session
//// base policy this module is allowed to touch, where an execution's
//// files land, and the translation from the pipeline's vocabulary into
//// the one the model reads.
////
//// The orchestration seam is the exception, and deliberately so. Its
//// router calls the *real* Agency over a *real* runtime here, because the
//// property it has to have — that a program may address only the lineage
//// its own strand roots, refused under the names the `agent_*` tools
//// already refuse under — is one no fake can be evidence for. The
//// `codemode` package proves the carriage against a scripted Agency; this
//// is where the two halves meet.

import broker/broker
import broker/budget
import broker/escalation
import broker/exec
import broker/framing
import broker/policy
import client/agency
import client/codemode
import client/serve
import codemode/codemode as pipeline
import codemode/compile
import codemode/identity
import codemode/launch
import codemode/orchestration
import codemode/satellite
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/json
import core/message
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import simplifile
import tools/agent
import tools/codemode as codemode_tool
import tools/tool

// --- fixtures --------------------------------------------------------------

// A live broker whose helper source is always empty. Nothing in this
// module dispatches, but `Config` needs a real one and starting it is
// cheaper than pretending.
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
    toolchain: codemode.Toolchain(
      gleam_path: "/opt/gleam/bin/gleam",
      erl_path: "/usr/lib/erlang/bin/erl",
      seed_root: "/opt/loom/codemode-seed",
    ),
  )
}

fn an_op(seed: Int) -> OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn request_for(step: String) -> codemode_tool.Request {
  request_on(codemode_tool.WorkspaceSeam, step)
}

fn request_on(seam: codemode_tool.Seam, step: String) -> codemode_tool.Request {
  request_widened(seam, step, [])
}

// A request carrying whatever an approval attributed to this call. The
// empty list is the ordinary case; the widening tests pass a real grant.
fn request_widened(
  seam: codemode_tool.Seam,
  step: String,
  grants: List(policy.Grant),
) -> codemode_tool.Request {
  codemode_tool.Request(
    source: "pub fn main() { todo }",
    seam:,
    strand: "sub:main/sweep-1-0",
    op_id: an_op(3),
    step_id: step,
    source_index: 0,
    workspace: "/work",
    base_policy: policy.workspace_default("/work"),
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    within_ms: 60_000,
    grants:,
  )
}

// --- identity and budget ---------------------------------------------------

pub fn both_jailed_stages_run_under_the_callers_identity_test() {
  // The property the whole feature rests on: the build and the node are
  // dispatched under the *caller's* `{op_id, step_id}`, which is the
  // execution the broker pools budget under and the identity
  // `broker.abort` reaches. A minted one would mint a second budget and
  // put the satellite beyond the operation's abort.
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let request = request_for("turn-4:tools")
  let built =
    codemode.exec_config(config, request, "/work/x", 9000, widened_by: [])
  // One identity, and the keys it answers are the caller's own. Asserting
  // on `ledger_keys` rather than on a field pins the stronger property:
  // the build no longer carries coordinates that could disagree, so this
  // is the whole set of executions the broker will pool budget under.
  assert identity.ledger_keys(built.identity)
    == [#(request.op_id, "turn-4:tools")]
  broker.stop(broker_actor)
}

pub fn one_pooled_budget_covers_the_build_and_the_node_test() {
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let request = request_for("turn-4:tools")
  let built =
    codemode.exec_config(config, request, "/work/x", 9000, widened_by: [])
  // One ledger, now by construction: both phases derive from one identity,
  // so the budget cannot differ between them and the deadline is the one
  // the caller's `within_ms` produced rather than one this module invented.
  let pooled = identity.pooled_budget(identity.run_phase(built.identity))
  assert pooled == identity.pooled_budget(identity.build_phase(built.identity))
  assert pooled.deadline_ms == 9000
  // The node holds one outstanding effect for its whole life, so anything
  // below two starves the program's first capability call.
  assert pooled.max_outstanding >= codemode.minimum_outstanding
  broker.stop(broker_actor)
}

pub fn the_program_runs_in_the_callers_workspace_test() {
  let broker_actor = idle_broker()
  let request = request_for("turn-4:tools")
  let built =
    codemode.exec_config(
      config_for(broker_actor),
      request,
      "/work/x",
      9000,
      widened_by: [],
    )
  assert built.satellite.cwd == "/work"
  // The program's own children inherit the driver's constructed
  // environment, not the build's toolchain PATH.
  assert built.satellite.env == request.env
  assert built.satellite.demand == request.demand
  broker.stop(broker_actor)
}

// --- what an approved escalation widens ------------------------------------

pub fn an_approval_reaches_the_run_phase_test() {
  // Issue #24's whole point at this seam: an approved escalation's grants
  // ride the one threaded identity, so the node's clearance and every
  // capability call the program makes compose them. Before this they were
  // dropped and an approval widened nothing.
  let broker_actor = idle_broker()
  let grants = [policy.GrantNetwork(network: policy.NetworkFull)]
  let built =
    codemode.exec_config(
      config_for(broker_actor),
      request_for("turn-4:tools"),
      "/work/x",
      9000,
      widened_by: grants,
    )
  assert identity.grants(identity.run_phase(built.identity)) == grants
  broker.stop(broker_actor)
}

pub fn an_approval_never_reaches_the_hermetic_build_test() {
  // The other half, and the one with teeth. Composition applies grants
  // after the meet, so a `GrantNetwork` reaching the build phase would put
  // the network back on inside a build that is pinned and offline by
  // design. `identity.build_phase` drops them, so there is no widened
  // build phase for a clearance to be built from.
  let broker_actor = idle_broker()
  let built =
    codemode.exec_config(
      config_for(broker_actor),
      request_for("turn-4:tools"),
      "/work/x",
      9000,
      widened_by: [policy.GrantNetwork(network: policy.NetworkFull)],
    )
  assert identity.grants(identity.build_phase(built.identity)) == []
  broker.stop(broker_actor)
}

pub fn a_widening_opens_no_second_ledger_test() {
  // Grants are consent, not accounting. An approval that also bought a
  // second `{op_id, step_id}` would buy a second `max_outstanding` cap and
  // a second wall deadline with it.
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let request = request_for("turn-4:tools")
  let widened =
    codemode.exec_config(config, request, "/work/x", 9000, widened_by: [
      policy.GrantEnv(name: "CC"),
    ])
  // Against the caller's own coordinates rather than against an
  // unapproved execution's: both would go through `widened_by`, so
  // comparing them could only prove the two agree, never that either is
  // the pair the driver handed in.
  assert identity.ledger_keys(widened.identity)
    == [#(request.op_id, request.step_id)]
  broker.stop(broker_actor)
}

pub fn one_host_does_not_leak_an_approval_to_another_execution_test() {
  // There is no session-wide grant list anywhere below `Config`, so an
  // approval attributed to one execution cannot widen the next one. Two
  // executions off one host configuration, one approved and one not: the
  // unapproved one carries nothing, which is the property design §5.3
  // states as "one re-execution of the denied action, never a silent
  // session widening".
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let approved =
    codemode.exec_config(
      config,
      request_for("turn-4:tools"),
      "/work/x",
      9000,
      widened_by: [policy.GrantEnv(name: "CC")],
    )
  let plain =
    codemode.exec_config(
      config,
      request_for("turn-5:tools"),
      "/work/y",
      9000,
      widened_by: [],
    )
  assert identity.grants(identity.run_phase(approved.identity)) != []
  assert identity.grants(identity.run_phase(plain.identity)) == []
  broker.stop(broker_actor)
}

// --- the one policy dimension this module touches --------------------------

pub fn the_execution_policy_adds_only_the_two_cap_handles_test() {
  // The launcher sets `LOOM_CAP_SOCK` and `LOOM_CAP_TOKEN_FILE` itself,
  // and composition takes the meet — so a base that does not name them
  // composes them away and the satellite cannot find the channel it
  // exists to speak on. Adding exactly those two names is the whole of
  // what this module does to a session base; every other dimension must
  // come through untouched.
  let base = policy.workspace_default("/work")
  let widened = codemode.execution_policy(base)
  assert widened.writable_roots == base.writable_roots
  assert widened.readable_roots == base.readable_roots
  assert widened.protected == base.protected
  assert widened.network == base.network
  assert widened.limits == base.limits
  assert widened.scratch == base.scratch
  assert list.contains(widened.env_allow, "LOOM_CAP_SOCK")
  assert list.contains(widened.env_allow, "LOOM_CAP_TOKEN_FILE")
  // Nothing else joined the allowlist, and nothing left it.
  assert list.filter(widened.env_allow, fn(name) {
      name != "LOOM_CAP_SOCK" && name != "LOOM_CAP_TOKEN_FILE"
    })
    == base.env_allow
}

pub fn the_execution_policy_is_idempotent_test() {
  // A base that already names the handles gains nothing, so re-deriving
  // cannot grow a duplicate allowlist entry.
  let base =
    policy.SandboxPolicy(..policy.workspace_default("/work"), env_allow: [
      "PATH", "LOOM_CAP_SOCK", "LOOM_CAP_TOKEN_FILE",
    ])
  assert codemode.execution_policy(base) == base
}

pub fn the_pipeline_is_handed_the_widened_base_test() {
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let request = request_for("turn-4:tools")
  let built =
    codemode.exec_config(config, request, "/work/x", 9000, widened_by: [])
  assert built.satellite.base_policy
    == codemode.execution_policy(request.base_policy)
  assert codemode.build_config(config, request).base_policy
    == codemode.execution_policy(request.base_policy)
  broker.stop(broker_actor)
}

// --- where an execution's files live ---------------------------------------

pub fn an_execution_gets_its_own_directory_inside_the_workspace_test() {
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let first = codemode.exec_root(config, request_for("turn-1:tools"))
  let second = codemode.exec_root(config, request_for("turn-2:tools"))
  // Inside the workspace, so the session base already makes it writable
  // and no policy has to be widened to build there.
  assert string.starts_with(first, "/work/" <> codemode.work_directory <> "/")
  // Distinct per execution, so two strands running code mode at once
  // cannot share a build root.
  assert first != second
  broker.stop(broker_actor)
}

pub fn a_socket_path_stays_under_the_kernels_limit_test() {
  // The socket lives inside the execution's directory, and AF_UNIX paths
  // are capped at about 108 bytes — so the name has to be short enough
  // that an ordinary workspace leaves room. A digest and a one-character
  // socket name is what buys that room.
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let path = codemode.socket_path(codemode.exec_root(config, request_for("t")))
  assert string.length(path) <= codemode.max_socket_path_bytes
  broker.stop(broker_actor)
}

pub fn a_step_id_cannot_climb_out_of_the_work_root_test() {
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let root =
    codemode.exec_root(
      config,
      codemode_tool.Request(..request_for("x"), step_id: "../../etc/cron.d/x y"),
    )
  assert string.starts_with(root, "/work/" <> codemode.work_directory <> "/")
  assert !string.contains(root, "..")
  assert !string.contains(root, "/etc/")
  assert !string.contains(root, " ")
  // The name is a digest, so nothing a step id contains can reach a path
  // component at all.
  assert !string.contains(root, "cron")
  broker.stop(broker_actor)
}

pub fn the_socket_and_the_token_live_under_that_directory_test() {
  let broker_actor = idle_broker()
  let request = request_for("turn-4:tools")
  let built =
    codemode.exec_config(
      config_for(broker_actor),
      request,
      "/work/.codemode/one",
      9000,
      widened_by: [],
    )
  assert built.satellite.cap_socket_path == "/work/.codemode/one/s"
  assert built.compile.build_root == "/work/.codemode/one"
  broker.stop(broker_actor)
}

// --- translating the pipeline's vocabulary --------------------------------

pub fn a_vetting_rejection_keeps_its_rule_detail_and_span_test() {
  let translated =
    codemode.translate(
      pipeline.VetRejected([
        vet.Rejection(
          rule: vet.ImportNotAllowed,
          detail: "`gleam/io` is not an allowed import",
          location: vet.SourceSpan(start: 0, end: 15),
        ),
        vet.Rejection(
          rule: vet.NoForeignInterface,
          detail: "an attribute on `escape`",
          location: vet.Unlocated,
        ),
      ]),
    )
  assert translated
    == codemode_tool.VetRejected([
      codemode_tool.Rejection(
        rule: codemode_tool.ImportNotAllowed,
        detail: "`gleam/io` is not an allowed import",
        location: codemode_tool.SourceSpan(start: 0, end: 15),
      ),
      codemode_tool.Rejection(
        rule: codemode_tool.NoForeignInterface,
        detail: "an attribute on `escape`",
        location: codemode_tool.Unlocated,
      ),
    ])
}

pub fn a_parse_failure_keeps_its_byte_offset_test() {
  assert codemode.translate(
      pipeline.VetRejected([
        vet.Rejection(
          rule: vet.Unparseable,
          detail: "unexpected token",
          location: vet.SourcePoint(byte_offset: 12),
        ),
      ]),
    )
    == codemode_tool.VetRejected([
      codemode_tool.Rejection(
        rule: codemode_tool.Unparseable,
        detail: "unexpected token",
        location: codemode_tool.SourcePoint(byte_offset: 12),
      ),
    ])
}

pub fn compiler_diagnostics_cross_verbatim_test() {
  // The type checker doubles as the capability-argument validator, so its
  // words are the signal the model repairs from. Not summarized here.
  assert codemode.translate(
      pipeline.CompileFailed(compile.BuildRejected(
        diagnostics: "error: Type mismatch\n  Expected List(String)",
      )),
    )
    == codemode_tool.CompileFailed(codemode_tool.BuildRejected(
      diagnostics: "error: Type mismatch\n  Expected List(String)",
    ))
}

pub fn every_run_error_lands_in_one_of_four_buckets_test() {
  // Eight pipeline variants, four the model reads differently — and every
  // narrowing carries the original reason text rather than dropping it.
  assert codemode.translate(pipeline.RunFailed(satellite.DeadlineExceeded))
    == codemode_tool.RunFailed(codemode_tool.DeadlineExceeded)
  assert codemode.translate(
      pipeline.RunFailed(satellite.SatelliteGone(reason: "node exited 1")),
    )
    == codemode_tool.RunFailed(codemode_tool.SatelliteGone(
      reason: "node exited 1",
    ))
  let assert codemode_tool.RunFailed(codemode_tool.StartFailed(reason:)) =
    codemode.translate(
      pipeline.RunFailed(satellite.LaunchRejected(reason: "socket unreachable")),
    )
    as "a launch refusal is a start failure"
  assert reason == "socket unreachable"
  let assert codemode_tool.RunFailed(codemode_tool.StartFailed(reason: minted)) =
    codemode.translate(
      pipeline.RunFailed(satellite.TokenMintFailed(reason: "no entropy")),
    )
    as "a token fault is a start failure"
  assert string.contains(minted, "no entropy")
  let assert codemode_tool.RunFailed(codemode_tool.ChannelFaulted(
    reason: malformed,
  )) =
    codemode.translate(
      pipeline.RunFailed(satellite.OutcomeMalformed(reason: "not a map")),
    )
    as "a malformed terminal frame is a channel fault"
  assert string.contains(malformed, "not a map")
}

pub fn a_run_hands_back_the_outcome_and_the_content_address_test() {
  assert codemode.translate(pipeline.Ran(
      source: "pub fn main() { todo }",
      artifact: compile.Artifact(
        build_root: "/work/.codemode/one",
        beam_dir: "/work/.codemode/one/ebin",
        entry_module: compile.entry_module,
        manifest_hash: "sha256-deadbeef",
      ),
      outcome: satellite.Completed(value: msgpack.StringValue("counted 3")),
    ))
    == codemode_tool.Ran(
      outcome: codemode_tool.Completed(value: msgpack.StringValue("counted 3")),
      manifest_hash: "sha256-deadbeef",
    )
}

// --- discovery and registration --------------------------------------------

pub fn a_host_without_a_seed_says_why_test() {
  // Whatever this machine has, `/nonexistent` is not a prepared seed, and
  // the reason is worded for the startup line rather than being a bare
  // `Error(Nil)`.
  let assert Error(reason) = codemode.discover("/nonexistent/loom-seed")
    as "an absent seed must refuse"
  assert string.contains(reason, "seed") || string.contains(reason, "PATH")
  assert reason != ""
}

pub fn the_seam_publishes_the_policy_the_program_is_judged_against_test() {
  // The tool's description states the allowlist and the serviced
  // capabilities; reading them off the seam is what keeps that sentence
  // from drifting from the policy `execute` actually applies.
  let broker_actor = idle_broker()
  let seam = codemode.seam(config_for(broker_actor))
  let offered = seam.seams.default
  assert list.contains(offered.allowed_imports, "cap/report")
  assert list.contains(offered.allowed_imports, "cap/proc")
  assert !list.contains(offered.allowed_imports, "gleam/io")
  assert offered.serviced_caps == codemode.serviced_caps
  // A host serving one seam offers one, so the model is charged for no
  // choice it cannot make.
  assert seam.seams.alternates == []
  assert seam.default_within_ms <= seam.max_within_ms
  broker.stop(broker_actor)
}

pub fn code_mode_is_registered_only_where_a_pipeline_is_wired_test() {
  // Same arithmetic as the agent family: the wire tool array is the byte
  // prefix of the provider's cached region, so a permanently-refusing
  // definition would be paid for on every request of every strand. A host
  // with no toolchain simply has no `code_mode`.
  assert !list.contains(
    tool.names(serve.registry(None, None)),
    codemode_tool.tool_name,
  )
  let broker_actor = idle_broker()
  let seam = codemode.seam(config_for(broker_actor))
  let wired = tool.names(serve.registry(None, Some(seam)))
  assert list.contains(wired, codemode_tool.tool_name)
  assert list.length(wired) == 6
  broker.stop(broker_actor)
}

// --- the seam's own failure path -------------------------------------------

pub fn an_unusable_work_root_fails_in_band_test() {
  // `/proc` is not writable on any host this runs on, so the work
  // directory cannot be created — and that must be a value the model
  // reads, not a crash inside a tool call.
  let broker_actor = idle_broker()
  let config =
    codemode.Config(
      ..config_for(broker_actor),
      work_root: "/proc/loom-codemode",
    )
  let execution = codemode.execute(config, request_for("turn-4:tools"))
  let assert codemode_tool.CompileFailed(codemode_tool.WorkspaceSetupFailed(
    reason:,
  )) = execution.result
    as "an uncreatable work directory must settle in band"
  assert string.contains(reason, "/proc/loom-codemode")
  // Nothing ran, so nothing is claimed about enforcement — and both
  // stages say that themselves rather than being absent.
  let assert codemode_tool.Unreported(build) = execution.enforcement.build
  let assert codemode_tool.Unreported(node) = execution.enforcement.node
  assert string.contains(build, "nothing was dispatched")
  assert string.contains(node, "nothing was dispatched")
  broker.stop(broker_actor)
}

// --- the whole chain, without a toolchain ----------------------------------

pub fn a_forbidden_import_travels_the_real_pipeline_back_to_the_model_test() {
  // Vetting is pure and runs before the pipeline touches a compiler, a
  // helper or a socket — so this drives the *real* `codemode.execute`
  // through the *real* lint and out through the tool's rendering, on a
  // host with no toolchain and no jail. Everything between the model's
  // arguments and the model's answer is exercised except the two stages
  // `make e2e-codemode` owns.
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let work_root = here <> "/build/codemode-tool-test"
  let broker_actor = idle_broker()
  let config = codemode.Config(..config_for(broker_actor), work_root:)
  let seam = codemode.seam(config)
  let source = "import gleam/io\n\npub fn main() { io.println(\"hi\") }\n"
  let outcome =
    codemode_tool.tool_for(seam).run(
      ctx_for(work_root),
      json.Object([#("program", json.String(source))]),
    )
  assert outcome.is_error
  let text = rendered(outcome)
  // The rule, the offending import, and the allowlist to repair against.
  assert string.contains(text, "import not allowed")
  assert string.contains(text, "gleam/io")
  assert string.contains(text, "cap/report")
  let assert Some(json.Object(fields)) = outcome.details
    as "a rejection must carry structured details"
  assert list.contains(fields, #("status", json.String("vetting_rejected")))
  // Nothing ran, so nothing is said about the jail at all — neither a
  // report nor an empty one that could read as "unconfined".
  assert list.key_find(fields, "sandbox") == Error(Nil)
  assert !string.contains(text, "sandbox:")
  // And the execution left nothing behind. The root is computed for the
  // *same* step the context carried — a different one would be a path
  // that never existed and the assertion would pass for the wrong reason
  // — and with `link_info` rather than `is_file`, which answers
  // `Ok(False)` for a directory.
  let root = codemode.exec_root(config, request_for("turn-1:tools"))
  assert exists(work_root)
  assert !exists(root)
  broker.stop(broker_actor)
}

fn exists(path: String) -> Bool {
  case simplifile.link_info(path) {
    Ok(_info) -> True
    Error(_error) -> False
  }
}

fn rendered(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> text
      _other -> ""
    }
  })
  |> string.join("\n")
}

fn ctx_for(workspace: String) -> tool.Ctx {
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id: an_op(3),
    step_id: "turn-1:tools",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    clock: clock.fixed(at: 1000),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
  )
}

// --- the orchestration seam ------------------------------------------------

pub fn orchestrating_moves_the_allowlist_and_the_router_together_test() {
  // One field decides both, because a host that could set them apart
  // would eventually set them apart — and "which capabilities travel
  // together" is the whole of what the separation buys.
  let broker_actor = idle_broker()
  let config =
    codemode.orchestrating(config_for(broker_actor), over: none_agency())
  let seam = codemode.seam(config).seams.default
  assert list.contains(seam.allowed_imports, "cap/strand")
  assert list.contains(seam.allowed_imports, "cap/report")
  assert !list.contains(seam.allowed_imports, "cap/fs")
  assert !list.contains(seam.allowed_imports, "cap/proc")
  assert seam.serviced_caps == orchestration.serviced_caps
  assert codemode.surface_seam(config.surface) == vet_policy.OrchestrationSeam
  // And the workspace surface is unmoved by it.
  let workspace = codemode.seam(config_for(broker_actor)).seams.default
  assert list.contains(workspace.allowed_imports, "cap/proc")
  assert !list.contains(workspace.allowed_imports, "cap/strand")
  assert workspace.serviced_caps == codemode.serviced_caps
  broker.stop(broker_actor)
}

pub fn only_the_orchestration_surface_carries_a_spawn_ceiling_test() {
  // `agent_spawn` is throttled by turn cost and a loop pays nothing, so
  // the seam that replaces the turn with a loop is the one that needs an
  // explicit ceiling. The workspace seam mints nothing that outlives its
  // execution and declares none.
  let broker_actor = idle_broker()
  let request = request_for("turn-9:tools")
  let orchestrated =
    codemode.exec_config(
      codemode.orchestrating(config_for(broker_actor), over: none_agency()),
      request_on(codemode_tool.OrchestrationSeam, "turn-9:tools"),
      "/work/.codemode/x",
      9000,
      widened_by: [],
    )
  assert orchestrated.satellite.ceilings
    == orchestration.ceilings(orchestration.default_spawn_ceiling)
  let plain =
    codemode.exec_config(
      config_for(broker_actor),
      request,
      "/work/.codemode/x",
      9000,
      widened_by: [],
    )
  assert plain.satellite.ceilings == []
  broker.stop(broker_actor)
}

pub fn an_orchestration_program_is_vetted_against_its_own_seam_test() {
  // The whole pipeline, not just the policy value: a program importing
  // `cap/strand` is refused by a workspace host and admitted by an
  // orchestration one, both as the structured rejection the model reads.
  let broker_actor = idle_broker()
  let source = "import cap/report\nimport cap/strand\npub fn main() { 1 }\n"
  let request = codemode_tool.Request(..request_for("turn-9:tools"), source:)
  let refused = codemode.execute(config_for(broker_actor), request)
  let assert codemode_tool.VetRejected(rejections:) = refused.result
    as "a workspace host must refuse cap/strand"
  assert list.any(rejections, fn(one) {
    one.rule == codemode_tool.ImportNotAllowed
    && string.contains(one.detail, "cap/strand")
  })
  broker.stop(broker_actor)
}

// --- which seam a submission is judged against -----------------------------

pub fn a_submission_is_judged_against_the_seam_it_named_test() {
  // The real vetting pass, both directions, on one host that serves both
  // seams: the same program aimed at two seams is judged against two
  // allowlists, and the refusal is the structured one a model repairs
  // from. Nothing classifies a submission by reading its imports — that
  // would make the tool description a claim about a decision the harness
  // had already taken for itself.
  let broker_actor = idle_broker()
  let config =
    codemode.serving(
      config_for(broker_actor),
      codemode.BothSeams,
      over: none_agency(),
    )
  let orchestrating =
    codemode_tool.Request(
      ..request_on(codemode_tool.OrchestrationSeam, "turn-9:tools"),
      source: "import cap/report\nimport cap/strand\npub fn main() { 1 }\n",
    )
  // Admitted: vetting let it past, and what stopped it afterwards was the
  // absent toolchain rather than the allowlist.
  assert !is_vet_rejected(codemode.execute(config, orchestrating).result)
  // The same source aimed at the other seam this same host serves.
  let as_workspace =
    codemode_tool.Request(..orchestrating, seam: codemode_tool.WorkspaceSeam)
  assert refuses_import(
    codemode.execute(config, as_workspace).result,
    "cap/strand",
  )
  // And the confinement read the other way: an orchestration submission
  // reaching for an effect capability is refused by the same one rule.
  let effects =
    codemode_tool.Request(
      ..orchestrating,
      source: "import cap/fs\npub fn main() { 1 }\n",
    )
  assert refuses_import(codemode.execute(config, effects).result, "cap/fs")
  broker.stop(broker_actor)
}

pub fn a_seam_this_host_does_not_serve_dispatches_nothing_test() {
  // The tool shell refuses an unserved seam before `execute` is called,
  // so this is the second door: a caller that built its own request must
  // not have it quietly reinterpreted as the seam this host does serve.
  let broker_actor = idle_broker()
  let refused =
    codemode.execute(
      config_for(broker_actor),
      request_on(codemode_tool.OrchestrationSeam, "turn-4:tools"),
    )
  let assert codemode_tool.RunFailed(codemode_tool.StartFailed(reason:)) =
    refused.result
    as "an unserved seam must settle in band"
  assert string.contains(reason, "does not serve the orchestration")
  assert string.contains(reason, "it serves: workspace")
  // Nothing ran, and both stages say so rather than going missing.
  let assert codemode_tool.Unreported(build) = refused.enforcement.build
  let assert codemode_tool.Unreported(node) = refused.enforcement.node
  assert string.contains(build, "nothing was dispatched")
  assert string.contains(node, "nothing was dispatched")
  broker.stop(broker_actor)
}

pub fn a_host_serving_both_offers_both_and_defaults_to_the_workspace_test() {
  // What the model is told it may ask for is exactly what this host will
  // judge a submission against — the seams, their allowlists and their
  // serviced capabilities all read off the running surface.
  let broker_actor = idle_broker()
  let seam =
    codemode.seam(codemode.serving(
      config_for(broker_actor),
      codemode.BothSeams,
      over: none_agency(),
    ))
  assert seam.seams.default.seam == codemode_tool.WorkspaceSeam
  assert list.contains(seam.seams.default.allowed_imports, "cap/proc")
  let assert [orchestration_offer] = seam.seams.alternates
    as "a both-seams host must offer a second seam"
  assert orchestration_offer.seam == codemode_tool.OrchestrationSeam
  assert list.contains(orchestration_offer.allowed_imports, "cap/strand")
  assert !list.contains(orchestration_offer.allowed_imports, "cap/proc")
  assert orchestration_offer.serviced_caps == orchestration.serviced_caps
  broker.stop(broker_actor)
}

fn is_vet_rejected(result: codemode_tool.ExecResult) -> Bool {
  case result {
    codemode_tool.VetRejected(..) -> True
    codemode_tool.CompileFailed(..)
    | codemode_tool.RunFailed(..)
    | codemode_tool.Ran(..) -> False
  }
}

fn refuses_import(result: codemode_tool.ExecResult, module: String) -> Bool {
  case result {
    codemode_tool.VetRejected(rejections:) ->
      list.any(rejections, fn(one) {
        one.rule == codemode_tool.ImportNotAllowed
        && string.contains(one.detail, module)
      })
    codemode_tool.CompileFailed(..)
    | codemode_tool.RunFailed(..)
    | codemode_tool.Ran(..) -> False
  }
}

// --- the lineage rule, over a live runtime ---------------------------------

pub fn a_spawn_reaches_the_real_agency_test() {
  // The happy path first, because every refusal below would hold just as
  // well for a seam that refused everything.
  let live = start_runtime()
  let assert framing.CapOk(value:) =
    orchestrated(live, "main", "strand.spawn", spawn_args("review core"))
    as "a spawn from the root strand must be admitted"
  assert string.starts_with(child_of(value), "sub:main/review-core-")
}

pub fn a_spawn_from_a_child_hits_the_depth_cap_test() {
  // `depth_cap` is 1 — only the strand a human is talking to may spawn —
  // and it is counted from the durable lineage ledger, so a program
  // running on a child reaches it under the name the tools use.
  let live = start_runtime()
  let assert framing.CapOk(value:) =
    orchestrated(live, "main", "strand.spawn", spawn_args("review core"))
    as "the first spawn must be admitted"
  let child = child_of(value)
  let #(code, message) =
    refused(live, child, "strand.spawn", spawn_args("review deeper"))
  assert code == "depth_cap"
  assert string.contains(message, "capped at depth")
}

pub fn a_call_as_an_unknown_strand_fails_closed_test() {
  // The caller identity comes from the dispatching `Ctx`, never from the
  // program — and a name the session does not know is refused rather than
  // treated as a root with no constraints.
  let live = start_runtime()
  let #(code, message) =
    refused(live, "sub:main/nobody-9-9", "strand.spawn", spawn_args("review"))
  assert code == "not_addressable"
  assert string.contains(message, "sub:main/nobody-9-9")
}

pub fn a_send_outside_the_lineage_is_refused_by_name_test() {
  // The addressing rule, fail-closed: a strand with no lineage cell is a
  // root and is nobody's descendant, so "no lineage fact" answers
  // `not_addressable` rather than "unknown, allow".
  let live = start_runtime()
  let #(code, message) =
    refused(
      live,
      "main",
      "strand.send",
      msgpack.MapValue([
        pair("to", msgpack.StringValue("sub:elsewhere/nobody")),
        pair("text", msgpack.StringValue("hello")),
      ]),
    )
  assert code == "not_addressable"
  assert string.contains(message, "sub:elsewhere/nobody")
}

pub fn a_join_outside_the_lineage_is_refused_by_name_test() {
  // Joins are strictly downward, which is what keeps the wait graph
  // acyclic; a handle naming something the caller did not spawn is
  // `not_a_descendant`.
  let live = start_runtime()
  let #(code, message) =
    refused(
      live,
      "main",
      "strand.wait",
      msgpack.MapValue([
        pair(
          "handles",
          msgpack.ArrayValue([
            msgpack.MapValue([
              pair("strand", msgpack.StringValue("sub:elsewhere/nobody")),
              pair(
                "operation",
                msgpack.StringValue(ids.op_id_to_string(an_op(11))),
              ),
            ]),
          ]),
        ),
        pair("within_ms", msgpack.IntValue(1)),
      ]),
    )
  assert code == "not_a_descendant"
  assert string.contains(message, "sub:elsewhere/nobody")
}

// Routes one capability call through the production orchestration router
// over the live Agency, as the calling strand `from`, and runs the plan
// the way the satellite host's worker process does.
fn orchestrated(
  live: Live,
  from: String,
  cap: String,
  args: msgpack.MsgPackValue,
) -> framing.CapOutcome {
  let router =
    orchestration.router(orchestration.Orchestration(
      agency: live.seam,
      strand: from,
      source_index: 0,
    ))
  let request =
    satellite.CapRequest(
      cap:,
      args:,
      identity: identity.run_phase(identity.for_execution(
        op_id: an_op(5),
        step_id: "turn-9:tools",
        budget: budget.Budget(max_outstanding: 4, deadline_ms: 9_000_000),
      )),
      base_policy: policy.workspace_default("/work"),
      demand: exec.BestEffort,
      env: [],
      cwd: "/work",
      ordinal: 0,
    )
  case router(request) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(satellite.ServedHere(serve:)) -> serve()
    Ok(satellite.ClearedCall(..)) ->
      panic as "an orchestration call is never a jailed clearance"
  }
}

// The `{code, message}` a program reads when the call is refused.
fn refused(
  live: Live,
  from: String,
  cap: String,
  args: msgpack.MsgPackValue,
) -> #(String, String) {
  let assert framing.CapErr(code:, message:) =
    orchestrated(live, from, cap, args)
    as "the call must be refused"
  #(code, message)
}

fn child_of(value: msgpack.MsgPackValue) -> String {
  let assert msgpack.MapValue(entries:) = value as "a spawn answers a map"
  let assert Ok(msgpack.StringValue(strand)) =
    list.find_map(entries, fn(entry) {
      case entry.0 == msgpack.StringValue("strand") {
        True -> Ok(entry.1)
        False -> Error(Nil)
      }
    })
    as "a spawn answers with the child's strand"
  strand
}

fn spawn_args(purpose: String) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    pair("purpose", msgpack.StringValue(purpose)),
    pair("brief", msgpack.StringValue("look")),
    pair("within_ms", msgpack.NilValue),
    pair("detach", msgpack.BoolValue(False)),
    pair("context", msgpack.StringValue("fresh")),
    pair("tools", msgpack.NilValue),
    pair("result_schema", msgpack.NilValue),
  ])
}

fn pair(
  key: String,
  value: msgpack.MsgPackValue,
) -> #(msgpack.MsgPackValue, msgpack.MsgPackValue) {
  #(msgpack.StringValue(key), value)
}

fn none_agency() -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(agent.AgencyUnavailable) },
    wait: fn(_caller, _handles, _within) { Error(agent.AgencyUnavailable) },
    send: fn(_caller, _to, _text) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 30_000,
  )
}

// --- a live runtime behind a real Agency -----------------------------------
//
// The same shape `client/test/client/agency_test.gleam` uses, trimmed to
// what a refusal path needs: a memory session, an injected clock, and a
// provider that never settles, because no run has to finish for the
// lineage ledger to answer.

type Live {
  Live(seam: agent.Agency)
}

fn start_runtime() -> Live {
  let session_clock = counting_clock(1_756_000_000_000, 3)
  let assert Ok(sess) = session.open_memory(session_clock)
    as "the memory session must open"
  let assert Ok(counter) =
    actor.new(1)
    |> actor.on_message(fn(next, reply: Subject(Int)) {
      process.send(reply, next)
      actor.continue(next + 1)
    })
    |> actor.start
    as "the entropy counter must start"
  let entropy = fn() {
    7_000_000
    + process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
    * 104_729
  }
  let name = process.new_name(prefix: "loom_codemode_agency")
  let config =
    agency.Config(
      ..agency.default_config(name, counting_clock(1_756_000_000_000, 3)),
      rest: fn(_slice) { Nil },
      first_slice_ms: 1,
      max_slice_ms: 1,
    )
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: ["agent_spawn", "code_mode"],
    )
  let base = api.default_options(configuration)
  let assert Ok(runtime) =
    api.open(
      sess,
      effects.Effects(
        clock: session_clock,
        entropy:,
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(
          timeout_ms: 60_000,
          request: fn(_spec) {
            stream.StreamHandle(events: process.new_subject())
          },
        ),
        tools: effects.ToolSurface(
          clear: fn(_query) {
            effects.ClearanceRefused(reason: "no tools in this harness")
          },
          run: fn(_run) { effects.ToolFailed(reason: "no tools") },
          replay_still_safe: fn(_name) { False },
          execution_mode: fn(_name) { effects.ExclusiveExecution },
        ),
        hooks: effects.default_hooks(),
      ),
      api.Options(..base, poll_interval_ms: 25, subagent: agency.is_subagent),
    )
    as "the runtime must open"
  let assert Ok(_holder) = agency.start(config, runtime)
    as "the agency holder must start"
  Live(seam: agency.seam(config))
}

fn counting_clock(from: Int, by: Int) -> Clock {
  let assert Ok(counter) =
    actor.new(from)
    |> actor.on_message(fn(now, reply: Subject(Int)) {
      process.send(reply, now)
      actor.continue(now + by)
    })
    |> actor.start
    as "the clock counter must start"
  clock.from_function(fn() {
    process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
  })
}

// --- what a refusal reports outward (#97) ----------------------------------

// `launch_refusal` is the whole of the decision the watched launcher
// makes, and the only part of it a hermetic test can hold still: a
// `LaunchSpec` is a value, and "what does this base owe this node" is a
// pure function of one. The pipeline's own half — that a narrowed base
// really does refuse a real `erl` — is `make e2e-codemode`'s.

fn a_launch_spec(
  base: policy.SandboxPolicy,
  grants: List(policy.Grant),
) -> satellite.LaunchSpec {
  let root = "/work/.codemode/one"
  satellite.LaunchSpec(
    artifact: compile.Artifact(
      build_root: root,
      beam_dir: root <> "/ebin",
      entry_module: compile.entry_module,
      manifest_hash: "sha256-deadbeef",
    ),
    token_path: root <> "/token",
    cap_socket_path: root <> "/s",
    identity: identity.run_phase(
      identity.for_execution(
        op_id: an_op(3),
        step_id: "turn-1:tools",
        budget: budget.Budget(max_outstanding: 6, deadline_ms: 9000),
      )
      |> identity.widened_by(grants:),
    ),
    base_policy: base,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    wire: process.new_subject(),
  )
}

// The base a code-mode execution actually runs under: a session base wide
// enough to host a node, plus the two cap-channel names
// `execution_policy` adds. Wide on purpose, so the narrowing below is the
// only variable in these tests.
fn hosting_base() -> policy.SandboxPolicy {
  let base = policy.workspace_default("/work")
  codemode.execution_policy(
    policy.SandboxPolicy(..base, readable_roots: ["/"], env_allow: ["PATH"]),
  )
}

// The same base with the cap socket's environment name dropped — the
// narrowing the jailed end-to-end uses, and the sharpest one available:
// without that name the satellite cannot find the channel it exists to
// speak on, so it is a shortfall that genuinely stops the node rather
// than one the jail would shrug off.
fn without_the_cap_socket() -> policy.SandboxPolicy {
  let base = hosting_base()
  policy.SandboxPolicy(
    ..base,
    env_allow: list.filter(base.env_allow, fn(name) { name != launch.sock_env }),
  )
}

pub fn a_base_that_hosts_a_node_refuses_nothing_test() {
  // The negative half, and it earns its place: without it the test below
  // would pass just as well against a function that reported a refusal
  // whenever the launcher failed, whatever the reason.
  assert codemode.launch_refusal(
      a_launch_spec(hosting_base(), []),
      1000,
      "the launcher fell over for some other reason",
      9000,
    )
    == codemode_tool.NothingRefused
}

pub fn a_narrowed_base_reports_the_diff_that_would_open_it_test() {
  let assert codemode_tool.RunRefused(denial:, deadline_ms:) =
    codemode.launch_refusal(
      a_launch_spec(without_the_cap_socket(), []),
      1000,
      "the session base cannot host a satellite node: environment variable "
        <> launch.sock_env,
      9000,
    )
    as "a base missing the cap socket name must refuse the node"
  // The wanted diff is what an approval grants against, so it has to be
  // the grant that actually closes the shortfall rather than a
  // description of one: `broker/escalation.approve` refuses anything
  // outside it.
  assert denial.wanted == [policy.GrantEnv(name: launch.sock_env)]
  assert denial.source == escalation.PolicyDenial
  // The launcher's own sentence, carried verbatim: it is what a human
  // reads, and a paraphrase would be a second thing to keep in step.
  assert string.contains(denial.reason, launch.sock_env)
  // The refused execution's own budget deadline, which is what bounds the
  // window a human is given to answer in.
  assert deadline_ms == 9000
}

pub fn a_grant_that_closes_the_shortfall_reports_nothing_test() {
  // The same narrowed base with the approval in hand. This is what stops
  // the widened re-execution asking a second question about the thing a
  // human has just answered: the grants ride the spec's identity, and the
  // composition question is asked with them.
  assert codemode.launch_refusal(
      a_launch_spec(without_the_cap_socket(), [
        policy.GrantEnv(name: launch.sock_env),
      ]),
      1000,
      "unused",
      9000,
    )
    == codemode_tool.NothingRefused
}

pub fn an_execution_that_never_reached_a_launch_refuses_nothing_test() {
  // A build that cannot run mints nothing raisable. That is the decision
  // `PolicyRefusal` encodes rather than documents: an approval widens the
  // run phase and never the build — `identity.build_phase` drops this
  // execution's grants before the build composes anything — so a build
  // refused on policy is an operator's misconfiguration, and filing it
  // would be filing a question nobody can answer.
  //
  // The seed root here is absent, which fails the build before a launcher
  // exists. That is the same shape a build refused on policy has, since
  // either way no launch is reached and there is nothing to report.
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let broker_actor = idle_broker()
  let config =
    codemode.Config(
      ..config_for(broker_actor),
      work_root: here <> "/build/codemode-refusal-test",
      seed_root: "/nonexistent/loom-seed",
    )
  let request =
    codemode_tool.Request(
      ..request_for("turn-8:tools"),
      source: "import cap/report\n\npub fn main() -> report.Outcome {\n"
        <> "  report.text(\"hi\")\n}\n",
    )
  let execution = codemode.execute(config, request)
  let assert codemode_tool.CompileFailed(_failure) = execution.result
    as "an absent seed must fail the build"
  assert execution.refusal == codemode_tool.NothingRefused
  broker.stop(broker_actor)
}

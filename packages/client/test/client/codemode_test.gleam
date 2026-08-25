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

import broker/broker
import broker/exec
import broker/policy
import client/codemode
import client/serve
import codemode/codemode as pipeline
import codemode/compile
import codemode/satellite
import codemode/vet
import core/clock
import core/ids.{type OpId}
import core/json
import core/message
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
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
  codemode_tool.Request(
    source: "pub fn main() { todo }",
    strand: "sub:main/sweep-1-0",
    op_id: an_op(3),
    step_id: step,
    workspace: "/work",
    base_policy: policy.workspace_default("/work"),
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    within_ms: 60_000,
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
  let reports = process.new_subject()
  let built = codemode.exec_config(config, request, "/work/x", 9000, reports)
  assert built.exec_id
    == satellite.ExecId(op_id: request.op_id, step_id: "turn-4:tools")
  let build = codemode.build_config(config, request, 9000, reports)
  assert build.op_id == request.op_id
  assert build.step_id == "turn-4:tools"
  broker.stop(broker_actor)
}

pub fn one_pooled_budget_covers_the_build_and_the_node_test() {
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let request = request_for("turn-4:tools")
  let reports = process.new_subject()
  let built = codemode.exec_config(config, request, "/work/x", 9000, reports)
  let build = codemode.build_config(config, request, 9000, reports)
  // One ledger: same cap, same deadline, and the deadline is the one the
  // caller's `within_ms` produced rather than one this module invented.
  assert built.satellite.budget == build.budget
  assert built.satellite.budget.deadline_ms == 9000
  // The node holds one outstanding effect for its whole life, so anything
  // below two starves the program's first capability call.
  assert built.satellite.budget.max_outstanding >= codemode.minimum_outstanding
  broker.stop(broker_actor)
}

pub fn the_program_runs_in_the_callers_workspace_test() {
  let broker_actor = idle_broker()
  let request = request_for("turn-4:tools")
  let reports = process.new_subject()
  let built =
    codemode.exec_config(
      config_for(broker_actor),
      request,
      "/work/x",
      9000,
      reports,
    )
  assert built.satellite.cwd == "/work"
  // The program's own children inherit the driver's constructed
  // environment, not the build's toolchain PATH.
  assert built.satellite.env == request.env
  assert built.satellite.demand == request.demand
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
  let reports = process.new_subject()
  let built = codemode.exec_config(config, request, "/work/x", 9000, reports)
  assert built.satellite.base_policy
    == codemode.execution_policy(request.base_policy)
  assert codemode.build_config(config, request, 9000, reports).base_policy
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
  let reports = process.new_subject()
  let built =
    codemode.exec_config(
      config_for(broker_actor),
      request,
      "/work/.codemode/one",
      9000,
      reports,
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
  assert list.contains(seam.allowed_imports, "cap/report")
  assert list.contains(seam.allowed_imports, "cap/proc")
  assert !list.contains(seam.allowed_imports, "gleam/io")
  assert seam.serviced_caps == codemode.serviced_caps
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
  // Nothing ran, so nothing is claimed about enforcement.
  assert execution.enforcement == []
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

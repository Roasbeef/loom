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
import broker/dispatch
import broker/escalation
import broker/exec
import broker/framing
import broker/policy
import broker/token
import client/agency
import client/async_codemode
import client/async_runs
import client/codemode
import client/peer_mail
import client/peers
import client/remote/custodian
import client/remote/report_router
import client/remote/tool_custody
import client/serve
import client/workflows
import codemode/artifact
import codemode/build
import codemode/codemode as pipeline
import codemode/compile
import codemode/identity
import codemode/launch
import codemode/notes
import codemode/orchestration
import codemode/satellite
import codemode/search as search_router
import codemode/seed
import codemode/tool_gate
import codemode/vet
import codemode/vet/policy as vet_policy
import codemode/workspace
import core/clock.{type Clock}
import core/corruption
import core/ids.{type OpId}
import core/json
import core/message
import core/msgpack
import core/remote_tool
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/secret
import provider/stream
import runtime/api
import runtime/effects
import session/session
import simplifile
import storage/owner_custody
import storage/storage
import support/addresses
import support/internal/ffi_memory
import support/tool_registry
import tools/agent
import tools/codemode as codemode_tool
import tools/directory_access
import tools/fs
import tools/search
import tools/tool
import weft/actor
import weft/registry

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
    toolchain: codemode.toolchain(
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

// A request at a *real* source index, which is what tells one `code_mode`
// call apart from another in the same batch. The fixtures above hardcode
// zero, and a suite that only ever sees zero cannot observe the
// difference — which is exactly how the naming half of this shipped
// broken (issue #87, commit 063d9d5).
fn request_at(step: String, source_index: Int) -> codemode_tool.Request {
  codemode_tool.Request(..request_for(step), source_index:)
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
    directory_access: directory_access.none(),
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
    observe_output: tool.ignore_output(),
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
  // and composition takes the meet, so a base that does not name them
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

pub fn the_pipeline_is_handed_phase_specific_bases_test() {
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let request = request_for("turn-4:tools")
  let built =
    codemode.exec_config(config, request, "/work/x", 9000, widened_by: [])
  let sockets =
    codemode.socket_directory(
      config,
      op_id: request.op_id,
      step_id: request.step_id,
      source_index: request.source_index,
    )
  assert built.satellite.base_policy
    == codemode.reaching_socket_of(
      config,
      codemode.execution_policy(request.base_policy),
      sockets,
    )
  assert built.satellite.cap_socket_path == codemode.socket_path(sockets)
  let build_config = codemode.build_config(config, request)
  let run_base = codemode.execution_policy(request.base_policy)
  assert build_config.base_policy == run_base
  assert !list.contains(built.satellite.base_policy.env_allow, "TMPDIR")
  let call =
    build.build_call(
      build_config,
      identity.build_phase(built.identity),
      "/work/x",
    )
  assert list.contains(call.base_policy.env_allow, "TMPDIR")
  let #(effective, _narrowings) =
    policy.compose(
      base: call.base_policy,
      requirements: call.requirements,
      grants: [],
    )
  assert list.contains(effective.env_allow, "TMPDIR")
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

pub fn two_code_mode_calls_in_one_step_get_their_own_roots_test() {
  // `code_mode` is `tool.Exclusive`, which forbids a concurrent *start*
  // and nothing more: one batch may hold two `code_mode` calls that run
  // back to back under one operation and one step, differing only in
  // their source index. Keyed on the pair they would share a build root,
  // a cap socket and a token file — two hermetic builds writing one
  // directory, and a janitor from the first execution unlinking the
  // second's live socket. The third field is what ends that.
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let step = "turn-1:tools"
  let first = codemode.exec_root(config, request_at(step, 0))
  let second = codemode.exec_root(config, request_at(step, 1))
  assert first != second
  // Everything an execution owns hangs off the root, so one assertion
  // covers the socket and the token file too.
  assert codemode.socket_path(first) != codemode.socket_path(second)
  // Still a function of the coordinates and nothing else: the same call
  // names the same directory, which is what makes a re-execution under an
  // approval land where the first one did.
  assert codemode.exec_root(config, request_at(step, 1)) == second
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

// --- the socket root (#611) --------------------------------------------------

// A daemon's socket root, and a workspace deep enough that the old
// placement could not have bound a socket in it.
const daemon_sockets = "/home/o/.loom/run"

fn deep_config(broker_actor: broker.Broker) -> codemode.Config {
  let deep = "/" <> string.repeat("d", 149)
  codemode.default_config(
    broker: broker_actor,
    clock: clock.fixed(at: 1000),
    workspace: deep,
    toolchain: codemode.toolchain(
      gleam_path: "/opt/gleam/bin/gleam",
      erl_path: "/usr/lib/erlang/bin/erl",
      seed_root: "/opt/loom/codemode-seed",
    ),
  )
  |> codemode.sockets_under(Some(daemon_sockets))
}

pub fn a_deep_workspace_gets_a_socket_under_the_budget_test() {
  // The socket path is the socket root plus nineteen bytes whatever the
  // workspace is, and the execution directory stays in the workspace.
  let broker_actor = idle_broker()
  let config = deep_config(broker_actor)
  let request = request_for("turn-1:tools")
  let sockets =
    codemode.socket_directory(
      config,
      op_id: request.op_id,
      step_id: request.step_id,
      source_index: request.source_index,
    )
  assert string.starts_with(sockets, daemon_sockets <> "/")
  assert string.byte_size(codemode.socket_path(sockets))
    == string.byte_size(daemon_sockets) + 19
  assert codemode.check_socket_path(sockets) == Ok(Nil)
  assert string.starts_with(
    codemode.exec_root(config, request),
    config.work_root <> "/",
  )
  broker.stop(broker_actor)
}

pub fn a_too_deep_socket_root_is_refused_naming_the_root_test() {
  // The residual case: the socket root itself is too deep. The refusal
  // names that root, since moving the workspace would not help.
  let root = "/" <> string.repeat("r", 90)
  let assert Error(reason) =
    codemode.check_socket_path(root <> "/0000000000000000")
    as "a socket under a 91-byte root is over the budget"
  assert string.contains(reason, "the socket root " <> root <> " is too deep")
}

pub fn socket_directories_are_one_per_execution_and_workspace_test() {
  // Issue #87's key, carried to the socket root: distinct per source
  // index within one step, stable for the same coordinates, and distinct
  // for the same coordinates in another workspace, since one socket root
  // serves every workspace the daemon hosts.
  let broker_actor = idle_broker()
  let config = deep_config(broker_actor)
  let other =
    codemode.Config(
      ..config,
      work_root: "/elsewhere/" <> codemode.work_directory,
    )
  let op = an_op(7)
  let at = fn(config, index) {
    codemode.socket_directory(
      config,
      op_id: op,
      step_id: "turn-1:tools",
      source_index: index,
    )
  }
  assert at(config, 0) != at(config, 1)
  assert at(config, 1) == at(config, 1)
  assert at(config, 0) != at(other, 0)
  assert codemode.host_socket_directory(config, extension: "web")
    != codemode.host_socket_directory(other, extension: "web")
  broker.stop(broker_actor)
}

pub fn reaching_a_socket_lifts_only_the_mask_over_it_test() {
  // The satellite's base loses the socket root's mask and gains its own
  // directory as a readable root. A mask above the socket root and a mask
  // elsewhere are kept, and nothing else changes.
  let directory = daemon_sockets <> "/3c61d0b2a9e4f718"
  let base =
    policy.SandboxPolicy(
      ..policy.workspace_default("/work"),
      readable_roots: ["/work"],
      protected: [daemon_sockets, "/home/o/.loom/owner.token", "/work/.blobs"],
    )
  let reached =
    codemode.reaching_socket(base, under: daemon_sockets, directory:)
  assert reached.protected == ["/home/o/.loom/owner.token", "/work/.blobs"]
  assert reached.readable_roots == ["/work", directory]
  assert reached.writable_roots == base.writable_roots
  assert reached.env_allow == base.env_allow
  assert reached.network == base.network

  // A mask over the whole state root is above the socket root, so it
  // stays, and the launch then refuses because the socket is masked.
  let whole = policy.SandboxPolicy(..base, protected: ["/home/o/.loom"])
  assert codemode.reaching_socket(whole, under: daemon_sockets, directory:).protected
    == ["/home/o/.loom"]
}

pub fn only_the_satellite_base_reaches_the_socket_root_test() {
  // The build's base is derived without the socket grant, so the hermetic
  // build keeps the mask; the satellite's base reaches its one directory.
  let broker_actor = idle_broker()
  let config = deep_config(broker_actor)
  let request =
    codemode_tool.Request(
      ..request_for("turn-4:tools"),
      base_policy: policy.SandboxPolicy(
        ..policy.workspace_default("/work"),
        protected: [daemon_sockets],
      ),
    )
  let built = codemode.exec_config(config, request, "/work/x", 9000, [])
  assert !list.contains(built.satellite.base_policy.protected, daemon_sockets)
  assert list.contains(
    codemode.build_config(config, request).base_policy.protected,
    daemon_sockets,
  )
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

pub fn the_build_lives_in_that_directory_and_the_socket_beside_it_test() {
  // The build root is the execution directory; the socket is in its own
  // directory under the socket root (issue #611), which for a host that
  // names none is the work root.
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let request = request_for("turn-4:tools")
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture must have a working directory"
  let root = here <> "/build/codemode-selected-build-root"
  let _ = simplifile.delete(root)
  let built = codemode.exec_config(config, request, root, 9000, widened_by: [])
  assert built.satellite.cap_socket_path
    == codemode.socket_path(codemode.socket_directory(
      config,
      op_id: request.op_id,
      step_id: request.step_id,
      source_index: request.source_index,
    ))
  assert string.starts_with(built.satellite.cap_socket_path, config.work_root)
  assert built.compile.dependencies == compile.default_dependencies()

  // The whole service hides its local root. Check the selected directory
  // by exercising preparation, rather than replacing the original root
  // assertion with an inspection of unrelated service metadata.
  let source =
    "import cap/report\npub fn main() { report.text(\"selected\") }\n"
  let assert vet.Passed(vetted) = vet.vet(source, built.vet_policy)
    as "the root fixture must pass owner vetting"
  let _compiled =
    built.compile.compile(compile.CompileRequest(
      vetted:,
      dependencies: built.compile.dependencies,
      generated: [],
      identity: identity.build_phase(built.identity),
    ))
  assert simplifile.read(root <> "/src/" <> compile.program_module <> ".gleam")
    == Ok(source)
  assert simplifile.read(root <> "/gleam.toml")
    == Ok(compile.project_toml(compile.default_dependencies()))
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

pub fn the_seed_is_verified_at_the_path_it_will_be_mounted_at_test() {
  // The seed reaches `discover` from a `--codemode-seed` flag and is read
  // twice: `seed.verify` stats it and `toolchain_mounts` binds it. A path
  // with a `..` segment verified as written and mounted expanded would be
  // two different directories, so the expansion happens once, at the top
  // of `discover`, and the refusal names the expanded path.
  let assert Error(reason) = codemode.discover("/nonexistent/loom/../loom-seed")
    as "an absent seed must refuse"
  assert !string.contains(reason, "loom/..")
}

pub fn the_seam_publishes_the_policy_the_program_is_judged_against_test() {
  // The tool's description states the allowlist and the serviced
  // capabilities; reading them off the seam is what keeps that sentence
  // from drifting from the policy `execute` actually applies.
  let broker_actor = idle_broker()
  let config = config_for(broker_actor)
  let seam = codemode.seam(config)
  let offered = seam.seams.default
  assert list.contains(offered.allowed_imports, "cap/report")
  assert list.contains(offered.allowed_imports, "cap/proc")
  assert !list.contains(offered.allowed_imports, "gleam/io")
  // Two routers' worth, read off the two modules that answer them: the
  // jailed `proc.run` and the harness-side bridge.
  assert offered.serviced_caps
    == codemode.seam_caps_on(config, vet_policy.WorkspaceSeam)
  assert list.contains(offered.serviced_caps, "proc.run")
  assert list.contains(offered.serviced_caps, "fs.read")
  // A host serving one seam offers one, so the model is charged for no
  // choice it cannot make.
  assert seam.seams.alternates == []
  assert seam.default_within_ms <= seam.max_within_ms
  broker.stop(broker_actor)
}

pub fn the_resident_seam_is_offered_to_no_program_test() {
  // The resident seam is the seam a harness-resident hook body would be
  // judged under if #32 ever built a loader, and the freeze rests on it
  // reaching nothing at all. Both halves of "nothing" live here rather
  // than in `codemode.gleam`'s `case` arms alone, where either could be
  // made permissive with a green suite: no capability is serviced for
  // it, and no `code_mode` tool is offered under it.
  assert codemode.seam_caps(vet_policy.ResidentSeam) == []
  assert codemode.tool_seam(vet_policy.ResidentSeam) == Error(Nil)
}

pub fn code_mode_is_registered_only_where_a_pipeline_is_wired_test() {
  // Same arithmetic as the agent family: the wire tool array is the byte
  // prefix of the provider's cached region, so a permanently-refusing
  // definition would be paid for on every request of every strand. A host
  // with no toolchain simply has no `code_mode`.
  assert !list.contains(
    tool.names(tool_registry.built_in(None, None, None, None, None)),
    codemode_tool.tool_name,
  )
  let broker_actor = idle_broker()
  let seam = codemode.seam(config_for(broker_actor))
  let wired =
    tool.names(tool_registry.built_in(None, Some(seam), None, None, None))
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
  let work_root = short_scratch_root() <> "/vet-order"
  let _cleared = simplifile.delete(work_root)
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
  assert !string.starts_with(codemode.socket_path(root), "/tmp/")
  assert bit_array.byte_size(<<codemode.socket_path(root):utf8>>)
    <= codemode.max_socket_path_bytes
  // A rejected submission must leave even the work-root parent absent. The
  // old prepare-before-vet order created this parent and removed only `root`.
  assert !exists(work_root)
  assert !exists(root)
  broker.stop(broker_actor)
}

// A shallow, host-owned base keeps AF_UNIX paths below the cross-platform
// budget without placing them under /tmp, which the jail replaces. The
// in-tree fallback remains guarded by the byte-budget assertion above.
fn short_scratch_root() -> String {
  case secret.lookup(secret.env(), "LOOM_TEST_SCRATCH") {
    Ok(scratch) -> scratch <> "/client"
    Error(Nil) ->
      case secret.lookup(secret.env(), "HOME") {
        Ok(home) -> home <> "/.loom-client-test"
        Error(Nil) -> {
          let assert Ok(here) = simplifile.current_directory()
            as "the test runner must have a working directory"
          here <> "/build/client-test"
        }
      }
  }
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
    directory_access: directory_access.none(),
    workspace: tool.LocalWorkspace(workspace, dead_filesystem()),
    strand: "main",
    op_id: an_op(3),
    step_id: "turn-1:tools",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    clock: clock.fixed(at: 1000),
    owner_blobs: tool.OwnerBlobs(workspace <> "/.blobs", dead_filesystem()),
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}

// --- the orchestration seam ------------------------------------------------

pub fn the_wait_ceiling_wins_the_race_test() {
  // The Agency's bound must be the one that fires. A `ServedHere` call
  // the satellite host gives up on is answered `unsettled` and its worker
  // killed, so if the host's bound came first every `strand.wait` would
  // answer `unsettled` — never `Ready`, however promptly the child
  // finished, and the join would be cut short as well. The same shape as
  // `the_mcp_call_timeout_wins_the_race_test`, for the other capability
  // that answers on a bound of its own.
  let config = agency.default_config(addresses.new(), clock.fixed(at: 0))
  assert config.max_wait_ms < codemode.default_call_timeout_ms
}

pub fn orchestrating_offers_the_full_capability_set_test() {
  let broker_actor = idle_broker()
  let config =
    codemode.orchestrating(config_for(broker_actor), over: none_agency())
  let seam = codemode.seam(config).seams.default
  assert list.contains(seam.allowed_imports, "cap/strand")
  assert list.contains(seam.allowed_imports, "cap/report")
  assert list.contains(seam.allowed_imports, "cap/fs")
  assert list.contains(seam.allowed_imports, "cap/proc")
  assert seam.serviced_caps
    == codemode.seam_caps_on(config, vet_policy.OrchestrationSeam)
  assert codemode.surface_seam(config.surface) == vet_policy.OrchestrationSeam
  // A host without an Agency cannot offer strand calls.
  let workspace = codemode.seam(config_for(broker_actor)).seams.default
  assert list.contains(workspace.allowed_imports, "cap/proc")
  assert !list.contains(workspace.allowed_imports, "cap/strand")
  assert !list.contains(workspace.serviced_caps, "strand.spawn")
  broker.stop(broker_actor)
}

pub fn configured_surfaces_carry_their_admission_ceilings_test() {
  // A call is throttled by turn cost and a loop pays nothing, so the seam
  // that replaces the turn with a loop is the one that needs explicit
  // ceilings — on every call that mints something outliving the
  // execution, which is four of the orchestration seam's six `strand.*`
  // calls. The workspace seam's `fs.*` and `kv.*` mint nothing that
  // outlives their execution; `report.emit` does, on both seams, so it is
  // the one ceiling they share and the reason the workspace list is no
  // longer empty.
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
  let workspace_ceilings = [artifact.ceiling(artifact.default_emit_ceiling)]
  assert orchestrated.satellite.ceilings
    == list.append(
      workspace_ceilings,
      orchestration.ceilings(
        orchestration.default_spawn_ceiling,
        emit_admissions: artifact.default_emit_ceiling,
      )
        |> list.filter(fn(ceiling) { ceiling.cap != artifact.emit_cap }),
    )
    |> list.append(notes.ceilings())
  let plain =
    codemode.exec_config(
      config_for(broker_actor),
      request,
      "/work/.codemode/x",
      9000,
      widened_by: [],
    )
  assert plain.satellite.ceilings
    == [
      artifact.ceiling(artifact.default_emit_ceiling),
    ]
  broker.stop(broker_actor)
}

pub fn report_authority_installs_surface_route_and_quota_together_test() {
  let broker_actor = idle_broker()
  let base = config_for(broker_actor)
  let session_id = ids.mint_session(ids.generator(clock.fixed(1000), 99)).0
  let assert Ok(limits) = owner_custody.limits(8, 32, 32_000_000, 262_144)
    as "The owner admission limits are valid."
  let assert Ok(owner_config) =
    custodian.config(
      "/unopened-owner.db",
      session_id,
      limits,
      1,
      1000,
      fn(_, _, _) {
        effects.ToolFailed("This assembly test never runs a tool.")
      },
    )
    as "A finite owner configuration can allocate an address."
  let assert Ok(names) = registry.start() as "The address registry starts."
  let owner = custodian.new(names, owner_config)
  let configured =
    codemode.over_reports(base, Some(codemode.ReportReader(owner, session_id)))

  // No actor or database is started: this proves the route is selected before
  // a malformed report call can touch owner custody or workspace fallback.
  let call =
    satellite.CapRequest(
      report_router.capability,
      msgpack.NilValue,
      identity.run_phase(identity.for_execution(
        an_op(9),
        "read",
        budget.Budget(4, 9000),
      )),
      policy.workspace_default("/work"),
      exec.BestEffort,
      [],
      "/work",
      0,
    )
  list.each(
    [codemode_tool.WorkspaceSeam, codemode_tool.OrchestrationSeam],
    fn(seam) {
      let request = request_on(seam, "report-reader")
      let before = codemode.exec_config(base, request, "/work/x", 9000, [])
      let after = codemode.exec_config(configured, request, "/work/x", 9000, [])
      assert after.satellite.ceilings
        == list.append(before.satellite.ceilings, report_router.ceilings())
      assert after.satellite.router(call)
        == Error(satellite.CapDenial(
          "invalid_argument",
          "Expected exactly reference text and offset integer.",
        ))
      assert before.satellite.router(call) != after.satellite.router(call)
    },
  )

  // The surface list and the actual execution configuration share the same
  // optional authority. Removing it restores both quotas and declarations.
  list.each([vet_policy.WorkspaceSeam, vet_policy.OrchestrationSeam], fn(seam) {
    assert !list.contains(
      codemode.seam_caps_on(base, seam),
      report_router.capability,
    )
    assert list.contains(
      codemode.seam_caps_on(configured, seam),
      report_router.capability,
    )
    assert codemode.seam_caps_on(codemode.over_reports(configured, None), seam)
      == codemode.seam_caps_on(base, seam)
  })
  list.each([vet_policy.ExtensionSeam, vet_policy.ResidentSeam], fn(seam) {
    assert !list.contains(
      codemode.seam_caps_on(configured, seam),
      report_router.capability,
    )
  })
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
  // Both selections admit the full capability set on an Agency-backed
  // host. The same source reaches the build stage under either selection.
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
  assert !is_vet_rejected(codemode.execute(config, as_workspace).result)

  // Effect imports are admitted in orchestration mode too.
  let effects =
    codemode_tool.Request(
      ..orchestrating,
      source: "import cap/fs\npub fn main() { 1 }\n",
    )
  assert !is_vet_rejected(codemode.execute(config, effects).result)
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
  assert list.contains(seam.seams.default.allowed_imports, "cap/strand")
  let assert [orchestration_offer] = seam.seams.alternates
    as "a both-seams host must offer a second seam"
  assert orchestration_offer.seam == codemode_tool.OrchestrationSeam
  assert list.contains(orchestration_offer.allowed_imports, "cap/strand")
  assert list.contains(orchestration_offer.allowed_imports, "cap/proc")
  assert orchestration_offer.serviced_caps == seam.seams.default.serviced_caps
  list.each([seam.seams.default, orchestration_offer], fn(offer) {
    assert list.contains(offer.allowed_imports, "cap/peer")
    let mode =
      codemode_tool.CodeMode(..seam, seams: codemode_tool.one_seam(offer))
    let assert Ok(surface) =
      codemode_tool.cap_scheme(mode).read(ctx_for("/work"), "peer")
      as "the default Agency-backed host exposes own message inspection"
    assert string.contains(
      surface,
      "pub fn inbox(after: PendingCursor, limit: Int)",
    )
    assert string.contains(
      surface,
      "pub fn history(before: HistoryCursor, limit: Int)",
    )
    assert string.contains(
      surface,
      "pub fn received(after: ReceiptCursor, limit: Int)",
    )
  })
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

// --- the lineage rule, over a live runtime ---------------------------------

pub fn every_client_router_capability_is_decided_test() {
  // `codemode/tool_gate_test` walks this package's routers; this walks the
  // client's, so a capability added to any router has to be classified as
  // gated or open before the suite passes.
  let serviced =
    list.flatten([
      codemode.serviced_caps,
      peers.serviced_caps,
      workflows.serviced_caps,
      async_codemode.serviced_caps,
    ])
  assert list.filter(serviced, fn(cap) { !tool_gate.decided(cap) }) == []
}

pub fn a_strand_without_fs_write_is_refused_and_one_with_it_is_served_test() {
  // The live pair for the whole gate: two children of the real Agency, one
  // narrowed to exclude `fs_write` and one narrowed to hold it, each
  // calling `fs.write` through the host's two steps in the host's order.
  // The refused child leaves no file; the other writes one.
  let live = start_runtime()
  let dir = short_scratch_root() <> "/gate-write"
  let _gone = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the workspace must be creatable"
  let silent = child_with_tools(live, "read-only", ["code_mode"])
  let writer = child_with_tools(live, "writer", ["code_mode", "fs_write"])
  let write = fn(strand: String, name: String) {
    gated_write(live, strand, dir, name)
  }
  let assert framing.CapErr(code:, message:) = write(silent, "denied.txt")
    as "a strand without fs_write must be refused"
  assert code == "tool_not_held"
  assert message == "fs.write needs fs_write, which this strand does not hold"
  assert simplifile.read(dir <> "/denied.txt") |> result.is_error
    as "nothing was written for the refused strand"
  let assert framing.CapOk(..) = write(writer, "allowed.txt")
    as "a strand with fs_write must be served"
  assert simplifile.read(dir <> "/allowed.txt") == Ok("hello")
  let _cleaned = simplifile.delete(dir)
  Nil
}

// Spawns a child of `main` narrowed to `tools` and answers its strand.
fn child_with_tools(
  live: Live,
  purpose: String,
  tools: List(String),
) -> String {
  let args =
    msgpack.MapValue([
      pair("purpose", msgpack.StringValue(purpose)),
      pair("brief", msgpack.StringValue("look")),
      pair("within_ms", msgpack.NilValue),
      pair("detach", msgpack.BoolValue(False)),
      pair("context", msgpack.StringValue("fresh")),
      pair("tools", msgpack.ArrayValue(list.map(tools, msgpack.StringValue))),
      pair("result_schema", msgpack.NilValue),
    ])
  let assert framing.CapOk(value:) =
    orchestrated(live, "main", "strand.spawn", args)
    as "the narrowed spawn must be admitted"
  child_of(value)
}

// One `fs.write` as `strand`, the way the host runs a call: the tool check
// first, then the plan the workspace router builds, served.
fn gated_write(
  live: Live,
  strand: String,
  dir: String,
  name: String,
) -> framing.CapOutcome {
  let broker_actor = idle_broker()
  let seam =
    codemode.workspace_seam_for(
      config_for(broker_actor),
      workspace: dir,
      strand:,
      operation: an_op(5),
      protected: [],
    )
  broker.stop(broker_actor)
  let request =
    satellite.CapRequest(
      cap: "fs.write",
      args: msgpack.MapValue([
        pair("path", msgpack.StringValue(name)),
        pair("contents", msgpack.StringValue("hello")),
      ]),
      identity: identity.run_phase(identity.for_execution(
        op_id: an_op(5),
        step_id: "turn-9:tools",
        budget: budget.Budget(max_outstanding: 4, deadline_ms: 9_000_000),
      )),
      base_policy: policy.workspace_default(dir),
      demand: exec.BestEffort,
      env: [],
      cwd: dir,
      ordinal: 0,
    )
  case tool_gate.precheck(live.seam.holds, strand, 0)(request) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(Nil) -> {
      let assert Ok(satellite.ServedHere(serve:)) =
        workspace.routing(seam, over: satellite.default_router)(request)
        as "fs.write is served in the harness"
      serve()
    }
  }
}

pub fn every_seam_selection_carries_the_strand_tool_check_test() {
  // The tool list gates workspace-only programs too, so the check comes
  // from the Agency whichever seams are served, and a host with no
  // messaging plane has none to consult.
  let broker_actor = idle_broker()
  let base = config_for(broker_actor)
  assert option.is_none(base.strand_tools)
  list.each(
    [codemode.WorkspaceOnly, codemode.OrchestrationOnly, codemode.BothSeams],
    fn(seams) {
      let served = codemode.serving(base, seams, over: none_agency())
      assert option.is_some(served.strand_tools)
    },
  )
  broker.stop(broker_actor)
}

pub fn a_spawn_reaches_the_real_agency_test() {
  // The happy path first, because every refusal below would hold just as
  // well for a seam that refused everything.
  let live = start_runtime()
  let assert framing.CapOk(value:) =
    orchestrated(live, "main", "strand.spawn", spawn_args("review core"))
    as "a spawn from the root strand must be admitted"
  assert string.starts_with(child_of(value), "sub:main/review-core-")
}

pub fn a_spawn_from_a_child_is_refused_by_its_tool_list_test() {
  // Only the strand a human is talking to may spawn, and the Agency
  // enforces that by never giving a child `agent_spawn`. A program running
  // on the child is held to the same list, so the router refuses it for
  // want of the tool before the Agency's own depth cap is consulted; that
  // cap is proved against the live Agency in `agency_test`.
  let live = start_runtime()
  let assert framing.CapOk(value:) =
    orchestrated(live, "main", "strand.spawn", spawn_args("review core"))
    as "the first spawn must be admitted"
  let child = child_of(value)
  let #(code, message) =
    refused(live, child, "strand.spawn", spawn_args("review deeper"))
  assert code == "tool_not_held"
  assert string.contains(message, "agent_spawn")
}

pub fn a_notes_read_without_agent_notes_is_refused_by_the_router_test() {
  // A child spawned with a narrowed tool list may not read the blackboard
  // from a program, and the refusal is the router's own, in the sentence a
  // program reads: the Agency, which would serve a child this read, is never
  // asked. The messaging floor gives every child agent_send and agent_note
  // but never agent_notes, so this is a gate the floor cannot open.
  let live = start_runtime()
  let silent =
    msgpack.MapValue([
      pair("purpose", msgpack.StringValue("review core")),
      pair("brief", msgpack.StringValue("look")),
      pair("within_ms", msgpack.NilValue),
      pair("detach", msgpack.BoolValue(False)),
      pair("context", msgpack.StringValue("fresh")),
      pair("tools", msgpack.ArrayValue([msgpack.StringValue("code_mode")])),
      pair("result_schema", msgpack.NilValue),
    ])
  let assert framing.CapOk(value:) =
    orchestrated(live, "main", "strand.spawn", silent)
    as "the narrowed spawn must be admitted"
  let child = child_of(value)
  let #(code, message) =
    refused(
      live,
      child,
      "strand.notes",
      msgpack.MapValue([pair("prefix", msgpack.NilValue)]),
    )
  assert code == "tool_not_held"
  assert message
    == "strand.notes needs agent_notes, which this strand does not hold"
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
      emit: fn(_artifact) { Ok("sha256-unused") },
      emit_ceiling: artifact.default_emit_ceiling,
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
  // The host runs the strand's tool check in the call's worker before it
  // serves the plan; this does the same two steps in the same order.
  case tool_gate.precheck(live.seam.holds, from, 0)(request) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(Nil) ->
      case router(request) {
        Error(denial) ->
          framing.CapErr(code: denial.code, message: denial.message)
        Ok(satellite.ServedHere(serve:))
        | Ok(satellite.ScopedService(serve:)) -> serve()
        Ok(satellite.ClearedCall(..)) ->
          panic as "an orchestration call is never a jailed clearance"
      }
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
    send: fn(_caller, _to, _text, _within_ms) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    todos: fn(_caller, _step) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 30_000,
    model_names: [],
    holds: fn(_caller, _tool) { Ok(Nil) },
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
  start_runtime_over(fn(sess) { sess })
}

fn start_runtime_over(shape: fn(session.Session) -> session.Session) -> Live {
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
  let name = addresses.new()
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
      // The root strand holds every tool a program's capabilities are
      // gated on, as the shipped main does (`codemode/tool_gate`).
      active_tool_names: [
        "agent_note", "agent_notes", "agent_roster", "agent_send", "agent_spawn",
        "agent_wait", "bash", "code_mode", "fs_edit", "fs_write", "job_kill",
        "job_poll", "job_send", "peer_send", "schedule_cancel",
        "schedule_create", "schedule_list",
      ],
    )
  let base = api.default_options(configuration)
  let assert Ok(runtime) =
    api.open(
      shape(sess),
      effects.Effects(
        clock: session_clock,
        entropy:,
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(
          timeout_ms: 60_000,
          request: fn(_spec) {
            stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
          },
        ),
        tools: effects.ToolSurface(
          recover: fn(_run, _complete) { effects.UnmanagedLocal },
          clear: fn(_query) {
            effects.ClearanceRefused(reason: "no tools in this harness")
          },
          run: fn(_run) { effects.ToolFailed(reason: "no tools") },
          replay_still_safe: fn(_name) { False },
          execution_mode: fn(_name) { effects.ExclusiveExecution },
        ),
        hooks: effects.default_hooks(),
      ),
      api.Options(
        ..base,
        poll_interval_ms: 25,
        idle_poll_interval_ms: 25,
        subagent: agency.is_subagent,
      ),
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
      [],
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
      [],
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
      [],
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

// --- the toolchain's install prefixes (#242) --------------------------------

// A binary is not a toolchain: `erl` loads an ERTS install tree beside it,
// and a Homebrew `gleam` is a symlink into a versioned cellar directory.
// `install_prefix` is what names the region a jail has to carry, and it is
// a heuristic over path text, so the layouts it has to get right are
// written down here rather than left to the one host a developer is on.

pub fn a_packaged_erl_takes_the_prefix_above_bin_test() {
  // Debian and Ubuntu: /usr/bin/erl with the install tree at
  // /usr/lib/erlang.
  assert codemode.install_prefix("/usr/bin/erl") == "/usr"
}

pub fn an_otp_install_root_is_its_own_prefix_test() {
  // The other layout: the install root itself holds bin/ beside erts-*.
  assert codemode.install_prefix("/usr/lib/erlang/bin/erl") == "/usr/lib/erlang"
}

pub fn a_release_erl_climbs_past_its_erts_directory_test() {
  // A loom release ships <root>/erts-<vsn>/bin/erl and the emulator reads
  // lib/ and releases/ from <root>, so the erts directory alone would be a
  // jail with an erl that cannot boot.
  assert codemode.install_prefix("/opt/loom/erts-17.0.5/bin/erl") == "/opt/loom"
}

pub fn a_symlinked_gleam_keeps_the_prefix_holding_both_ends_test() {
  // /opt/homebrew/bin/gleam points at ../Cellar/gleam/1.18.1/bin/gleam.
  // The prefix is the directory holding the link *and* its target, which
  // is why the link is not resolved: naming the cellar would leave the bin
  // entry PATH uses outside the mount.
  assert codemode.install_prefix("/opt/homebrew/bin/gleam") == "/opt/homebrew"
}

pub fn a_binary_outside_a_bin_directory_keeps_its_own_directory_test() {
  // Nothing more can be said about a layout this does not recognize, and
  // the ERTS check in `discover` is what refuses it if it is wrong.
  assert codemode.install_prefix("/home/o/toolchains/erl")
    == "/home/o/toolchains"
}

pub fn the_toolchain_mounts_are_read_only_and_required_test() {
  let found =
    codemode.toolchain(
      gleam_path: "/opt/homebrew/bin/gleam",
      erl_path: "/usr/bin/erl",
      seed_root: "/opt/loom/share/codemode-seed",
    )
  assert codemode.toolchain_mounts(found)
    == [
      policy.Mount(
        path: "/usr",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
      policy.Mount(
        path: "/opt/loom/share/codemode-seed",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
      policy.Mount(
        path: "/opt/homebrew/bin",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ]
}

pub fn a_plain_gleam_binary_mounts_only_its_own_directory_test() {
  // The prefix of a developer install is `~/.cargo` or `~/.local`, whose
  // other subdirectories hold credentials and state. Only the directory
  // the binary is actually in belongs in a jail.
  let found =
    codemode.toolchain(
      gleam_path: "/home/o/.cargo/bin/gleam",
      erl_path: "/usr/bin/erl",
      seed_root: "/opt/seed",
    )
  assert list.contains(
    list.map(codemode.toolchain_mounts(found), fn(mount) { mount.path }),
    "/home/o/.cargo/bin",
  )
  assert !list.contains(
    list.map(codemode.toolchain_mounts(found), fn(mount) { mount.path }),
    "/home/o/.cargo",
  )
}

pub fn a_symlinked_gleam_binary_keeps_its_prefix_test() {
  // A Homebrew `bin/gleam` points into a versioned cellar directory
  // outside its own `bin`, and nothing here can read a link target, so
  // the prefix that contains both ends comes back.
  let found =
    codemode.Toolchain(
      ..codemode.toolchain(
        gleam_path: "/opt/homebrew/bin/gleam",
        erl_path: "/usr/bin/erl",
        seed_root: "/opt/seed",
      ),
      gleam_binary: codemode.GleamSymlink,
    )
  assert list.contains(
    list.map(codemode.toolchain_mounts(found), fn(mount) { mount.path }),
    "/opt/homebrew",
  )

  // The binary's own directory is inside the prefix, so the nested entry
  // is dropped rather than bound twice.
  assert !list.contains(
    list.map(codemode.toolchain_mounts(found), fn(mount) { mount.path }),
    "/opt/homebrew/bin",
  )
}

pub fn a_missing_gleam_binary_reads_as_a_plain_file_test() {
  // The mount is `MountRequired`, so a `gleam` that is not there refuses
  // the dispatch naming the directory rather than being guessed at here.
  assert codemode.gleam_binary_kind("/nowhere/at/all/gleam")
    == codemode.GleamPlainFile
}

pub fn one_prefix_holding_both_executables_is_mounted_once_test() {
  // A duplicate mount is a policy `validate` refuses, so the shared-prefix
  // host — every Homebrew host — must not produce one, and a seed inside
  // that prefix is the same region named twice.
  let found =
    codemode.toolchain(
      gleam_path: "/opt/homebrew/bin/gleam",
      erl_path: "/opt/homebrew/bin/erl",
      seed_root: "/opt/homebrew/share/codemode-seed",
    )
  assert list.map(codemode.toolchain_mounts(found), fn(mount) { mount.path })
    == ["/opt/homebrew"]
}

pub fn a_mount_path_is_canonical_before_it_reaches_a_policy_test() {
  // `--codemode-seed ../build/seed` is an ordinary thing to write, and
  // both sides of the wire refuse a `..` segment rather than resolve one,
  // so the resolution happens where the mount is built.
  let found =
    codemode.toolchain(
      gleam_path: "/opt/homebrew/bin/gleam",
      erl_path: "/usr/bin/erl",
      seed_root: "/srv/loom/packages/client/../../build/seed",
    )
  assert list.map(codemode.toolchain_mounts(found), fn(mount) { mount.path })
    == ["/usr", "/srv/loom/build/seed", "/opt/homebrew/bin"]
}

// --- a prefix that shadows the jail (protocol-change/057) --------------------

// The reproduction. On a merged-usr host `/bin` is a link to `usr/bin`,
// and a PATH listing `/bin` before `/usr/bin` finds `/bin/erl`. The
// prefix is the parent of that `bin`, which is `/`, and `discover`'s ERTS
// check passes it because `//lib/erlang` is `/usr/lib/erlang` through the
// same link. Every other region is inside `/`, so the list collapses to
// one read-only mount of the whole host — emitted after the workspace's
// writable bind, and after the fresh `/proc` and `/dev`.
pub fn a_merged_usr_erl_found_through_bin_takes_the_root_as_prefix_test() {
  assert codemode.install_prefix("/bin/erl") == "/"
  let found =
    codemode.toolchain(
      gleam_path: "/usr/bin/gleam",
      erl_path: "/bin/erl",
      seed_root: "/opt/seed",
    )
  assert codemode.toolchain_mounts(found)
    == [
      policy.Mount(
        path: "/",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ]
}

// The other ordinary host. `~/bin/gleam` linked to a checkout's build is
// a symlink, so its prefix is mounted too, and that prefix is the home
// directory the workspace usually sits in.
pub fn a_symlinked_gleam_in_home_bin_takes_the_home_directory_test() {
  let found =
    codemode.Toolchain(
      ..codemode.toolchain(
        gleam_path: "/home/o/bin/gleam",
        erl_path: "/usr/lib/erlang/bin/erl",
        seed_root: "/opt/seed",
      ),
      gleam_binary: codemode.GleamSymlink,
    )
  assert list.contains(
    list.map(codemode.toolchain_mounts(found), fn(mount) { mount.path }),
    "/home/o",
  )
}

pub fn a_toolchain_mounted_at_the_root_is_refused_test() {
  let found =
    codemode.toolchain(
      gleam_path: "/usr/bin/gleam",
      erl_path: "/bin/erl",
      seed_root: "/opt/seed",
    )
  let assert Error(reason) = codemode.clear_of(found, writable_roots: ["/work"])
  assert string.contains(reason, "code mode would mount / read-only")
  assert string.contains(reason, "the install prefix of `erl` at /bin/erl")
  assert string.contains(reason, "No code_mode tool is registered")
}

// A jail that names no writable root is no safer under `/`: the mount
// would bind the host's `/proc` and `/dev` back over the fresh ones,
// which is issue #37's confinement gap.
pub fn a_toolchain_mounted_at_the_root_is_refused_with_no_writable_root_test() {
  let found =
    codemode.toolchain(
      gleam_path: "/usr/bin/gleam",
      erl_path: "/bin/erl",
      seed_root: "/opt/seed",
    )
  let assert Error(reason) = codemode.clear_of(found, writable_roots: [])
  assert string.contains(reason, "that region contains /proc")
}

pub fn a_toolchain_prefix_above_the_workspace_is_refused_test() {
  let found =
    codemode.Toolchain(
      ..codemode.toolchain(
        gleam_path: "/home/o/bin/gleam",
        erl_path: "/usr/lib/erlang/bin/erl",
        seed_root: "/opt/seed",
      ),
      gleam_binary: codemode.GleamSymlink,
    )
  let assert Error(reason) =
    codemode.clear_of(found, writable_roots: ["/home/o/src/project"])
  assert string.contains(reason, "code mode would mount /home/o read-only")
  assert string.contains(reason, "contains /home/o/src/project")
  assert string.contains(reason, "the install prefix of `gleam` at")
}

// The layouts that must keep working, including the development one: a
// seed prepared inside the checkout is a read-only mount *under* the
// workspace, which narrows one subtree and shadows no writable root.
pub fn an_ordinary_toolchain_is_clear_of_the_workspace_test() {
  let found =
    codemode.toolchain(
      gleam_path: "/home/o/.cargo/bin/gleam",
      erl_path: "/usr/lib/erlang/bin/erl",
      seed_root: "/home/o/loom/build/codemode-seed",
    )
  assert codemode.clear_of(found, writable_roots: ["/home/o/loom"]) == Ok(found)
}

// --- the search bridge (#365) -------------------------------------------------

pub fn the_workspace_seam_advertises_the_search_capabilities_test() {
  // The description a model reads names what the router answers. Before
  // the search arm was composed into `workspace_router` this list held
  // the `fs.*` names alone, so a program could import `cap/search`,
  // compile, and meet `unsupported_cap` on its first call — the same
  // shape as issue #91's `report.emit`.
  let advertised = codemode.seam_caps(vet_policy.WorkspaceSeam)
  list.each(search_router.serviced_caps, fn(cap) {
    assert list.contains(advertised, cap)
  })
  // Both mode selections on an Agency-backed host route search.
  list.each(search_router.serviced_caps, fn(cap) {
    assert list.contains(codemode.seam_caps(vet_policy.OrchestrationSeam), cap)
  })
}

// A workspace with one ordinary file, one file behind a symlink pointing
// out of the tree, and the escape target itself.
type SearchFixture {
  SearchFixture(workspace: String, outside: String)
}

fn search_fixture(name: String) -> SearchFixture {
  let base = short_scratch_root() <> "/search-" <> name
  let _gone = simplifile.delete(base)
  let workspace = base <> "/work"
  let outside = base <> "/outside"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/src")
    as "the fixture workspace must be creatable"
  let assert Ok(Nil) = simplifile.create_directory_all(outside)
    as "the escape target must be creatable"
  let assert Ok(Nil) = simplifile.write(workspace <> "/src/app.gleam", "one\n")
    as "the fixture file must be writable"
  let assert Ok(Nil) = simplifile.write(outside <> "/secret.txt", "shh\n")
    as "the escape target's file must be writable"
  let assert Ok(Nil) = simplifile.create_symlink(outside, workspace <> "/away")
    as "the escaping symlink must be creatable"
  SearchFixture(workspace:, outside:)
}

// The narrowest query that matches anything, so what a test observes is
// the resolution rather than the pattern language.
fn a_glob() -> search.GlobQuery {
  search.GlobQuery(
    pattern: "*",
    max_entries: 10,
    hidden: search.SkipHidden,
    prune: [],
  )
}

pub fn a_search_root_above_the_workspace_is_refused_test() {
  // The containment claim, against a real filesystem: this is
  // `tools/fs.resolve_real`'s decision and the bridge's contribution is
  // to keep it structured. A scripted closure could not prove it, which
  // is why it is tested here and not in the router's own suite.
  let fixture = search_fixture("above")
  let seam = codemode.search_seam_for(workspace: fixture.workspace)
  assert seam.glob("../", a_glob())
    == Error(search_router.PathRefused(fs.EscapesWorkspace(path: "../")))
}

pub fn a_search_root_through_an_escaping_symlink_is_refused_test() {
  // The lexical hole the resolution closes: `away` is inside the
  // workspace and its target is not, so walking it would put the whole of
  // `outside` in reach of a read-only capability.
  let fixture = search_fixture("through")
  let seam = codemode.search_seam_for(workspace: fixture.workspace)
  assert seam.glob("away", a_glob())
    == Error(search_router.PathRefused(fs.EscapesWorkspace(path: "away")))
  // And so is a read through it, which resolves exactly as `fs.read`
  // does.
  assert seam.read_lines("away/secret.txt", 1, 1)
    == Error(
      search_router.PathRefused(fs.EscapesWorkspace(path: "away/secret.txt")),
    )
}

pub fn a_stat_reports_an_escaping_link_as_a_link_test() {
  // `stat` resolves the *parent* and lstats the leaf, so it answers what
  // is there — a symlink, with its stored target — rather than following
  // it and being refused. That is the whole reason the leaf is not
  // resolved: a program has to be able to see the link to route around
  // it.
  let fixture = search_fixture("stat")
  let seam = codemode.search_seam_for(workspace: fixture.workspace)
  let assert Ok(entry) = seam.stat("away")
    as "an lstat of a contained link must succeed"
  assert entry.path == "away"
  assert entry.kind == search.Symlink(target: fixture.outside)
  // And an ordinary file renders workspace-relative, so the path can be
  // handed straight back to `read_lines`.
  let assert Ok(file) = seam.stat("src/app.gleam")
    as "an lstat of an ordinary file must succeed"
  assert file.path == "src/app.gleam"
  assert file.kind == search.File
  assert seam.read_lines(file.path, 1, 1)
    == Ok(search.Lines(text: "one", first: 1, last: 1, total: 1))
}

pub fn a_glob_renders_its_entries_workspace_relative_test() {
  // The path an entry carries has to be usable as the argument of the
  // next call, which is what makes a walk composable at all. It is
  // rendered against the *resolved* workspace root, so a workspace that
  // itself sits behind a symlink still yields relative paths.
  let fixture = search_fixture("relative")
  let seam = codemode.search_seam_for(workspace: fixture.workspace)
  let assert Ok(listing) = seam.glob("src", a_glob())
    as "a walk of a contained root must succeed"
  assert list.map(listing.entries, fn(entry) { entry.path })
    == ["src/app.gleam"]
}

// An explicit workspace-only host installs notes without child custody.
// The description, vetted imports, router, and quotas must agree.
pub fn workspace_notes_are_available_only_when_the_host_wires_them_test() {
  let base = config_for(idle_broker())
  let config =
    codemode.serving(base, codemode.WorkspaceOnly, over: start_runtime().seam)
  assert !vet_policy.contains(
    codemode.seam_allowlist(base, vet_policy.WorkspaceSeam),
    "cap/notes",
  )
  assert vet_policy.contains(
    codemode.seam_allowlist(config, vet_policy.WorkspaceSeam),
    "cap/notes",
  )
  assert !vet_policy.contains(
    codemode.seam_allowlist(config, vet_policy.WorkspaceSeam),
    "cap/strand",
  )
  assert !vet_policy.contains(
    codemode.seam_allowlist(config, vet_policy.ExtensionSeam),
    "cap/notes",
  )
  assert !vet_policy.contains(
    codemode.seam_allowlist(config, vet_policy.ResidentSeam),
    "cap/notes",
  )
  assert list.contains(
    codemode.seam_caps_on(config, vet_policy.WorkspaceSeam),
    "notes.read",
  )
  assert !list.contains(
    codemode.seam_caps_on(base, vet_policy.WorkspaceSeam),
    "notes.read",
  )
  let text = codemode_tool.description(codemode.seam(config))
  assert string.contains(text, "notes.get")
  assert string.contains(text, "note://")
  assert !string.contains(
    codemode_tool.description(codemode.seam(base)),
    "### cap/notes",
  )
}

pub fn workspace_notes_use_the_real_blackboard_and_exact_keys_test() {
  let live = start_runtime()
  let config =
    codemode.serving(
      config_for(idle_broker()),
      codemode.WorkspaceOnly,
      over: live.seam,
    )
  let value =
    msgpack.MapValue([
      pair("items", msgpack.ArrayValue([msgpack.IntValue(3), msgpack.NilValue])),
    ])
  assert workspace_note_call(
      config,
      "notes.put",
      msgpack.MapValue([
        pair("key", msgpack.StringValue("analysis-old")),
        pair("value", msgpack.IntValue(9)),
      ]),
    )
    == framing.CapOk(msgpack.NilValue)
  assert workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([pair("key", msgpack.StringValue("main/analysis"))]),
    )
    == framing.CapOk(
      msgpack.MapValue([pair("found", msgpack.BoolValue(False))]),
    )
  assert workspace_note_call(
      config,
      "notes.put",
      msgpack.MapValue([
        pair("key", msgpack.StringValue("analysis")),
        pair("value", value),
      ]),
    )
    == framing.CapOk(msgpack.NilValue)
  assert workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([pair("key", msgpack.StringValue("main/analysis"))]),
    )
    == framing.CapOk(
      msgpack.MapValue([
        pair("found", msgpack.BoolValue(True)),
        pair("value", value),
      ]),
    )
  assert workspace_note_call(
      config,
      "notes.read",
      msgpack.MapValue([pair("key", msgpack.StringValue("main/analysis"))]),
    )
    == framing.CapOk(
      msgpack.MapValue([
        pair("contents", msgpack.StringValue("{\"items\":[3,null]}")),
      ]),
    )
  let assert framing.CapOk(msgpack.MapValue(cells)) =
    workspace_note_call(
      config,
      "notes.list",
      msgpack.MapValue([pair("prefix", msgpack.StringValue("main/analysis"))]),
    )
    as "list must read both cells"
  assert list.key_find(cells, msgpack.StringValue("notes"))
    == Ok(
      msgpack.ArrayValue([
        msgpack.MapValue([
          pair("key", msgpack.StringValue("main/analysis")),
          pair("value", value),
        ]),
        msgpack.MapValue([
          pair("key", msgpack.StringValue("main/analysis-old")),
          pair("value", msgpack.IntValue(9)),
        ]),
      ]),
    )
}

fn workspace_note_call(
  config: codemode.Config,
  cap: String,
  args: msgpack.MsgPackValue,
) -> framing.CapOutcome {
  routed_call(config, codemode_tool.WorkspaceSeam, cap, args)
}

fn routed_call(
  config: codemode.Config,
  seam: codemode_tool.Seam,
  cap: String,
  args: msgpack.MsgPackValue,
) -> framing.CapOutcome {
  let request =
    codemode_tool.Request(..request_on(seam, "cap-route-test"), strand: "main")
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
      ordinal: 0,
    )
  case pipeline.satellite.router(cap_request) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(satellite.ServedHere(serve)) | Ok(satellite.ScopedService(serve)) ->
      serve()
    Ok(satellite.ClearedCall(..)) ->
      panic as "these test calls are serviced by the host"
  }
}

pub fn both_modes_route_strand_and_workspace_calls_test() {
  let broker_actor = idle_broker()
  let config =
    codemode.serving(
      config_for(broker_actor),
      codemode.BothSeams,
      over: none_agency(),
    )

  let assert framing.CapErr(code: "strands_unavailable", ..) =
    routed_call(
      config,
      codemode_tool.WorkspaceSeam,
      "strand.roster",
      msgpack.MapValue([]),
    )
    as "workspace mode must route strand calls to the Agency"
  let assert framing.CapErr(code: fs_code, ..) =
    routed_call(
      config,
      codemode_tool.OrchestrationSeam,
      "fs.read",
      msgpack.MapValue([pair("path", msgpack.StringValue("missing.txt"))]),
    )
    as "orchestration mode must route workspace reads"
  assert fs_code != "unsupported_cap"
  broker.stop(broker_actor)
}

pub fn notes_reject_non_json_and_oversized_payloads_before_persistence_test() {
  // Duplicate keys are rejected before the capability router receives a value.
  let assert Ok(duplicate_frame) =
    msgpack.encode(
      msgpack.MapValue([
        pair(
          "value",
          msgpack.MapValue([
            pair("duplicate", msgpack.IntValue(1)),
            pair("duplicate", msgpack.IntValue(2)),
          ]),
        ),
      ]),
    )
    as "the hostile frame can be encoded"
  let assert Error(_) = msgpack.decode(duplicate_frame)
    as "the inbound wire decoder rejects nested duplicate keys"

  let live = start_runtime()
  let config =
    codemode.serving(
      config_for(idle_broker()),
      codemode.WorkspaceOnly,
      over: live.seam,
    )
  list.each(
    [
      msgpack.BinaryValue(<<1>>),
      msgpack.MapValue([#(msgpack.IntValue(1), msgpack.StringValue("bad"))]),
    ],
    fn(value) {
      let assert framing.CapErr(code: "invalid_argument", ..) =
        workspace_note_call(
          config,
          "notes.put",
          msgpack.MapValue([
            pair("key", msgpack.StringValue("invalid")),
            pair("value", value),
          ]),
        )
        as "lossy JSON conversions must be refused"
    },
  )
  let huge = msgpack.StringValue(string.repeat("x", notes.max_bytes))
  let assert framing.CapErr(code: "note_too_large", ..) =
    workspace_note_call(
      config,
      "notes.put",
      msgpack.MapValue([
        pair("key", msgpack.StringValue("huge")),
        pair("value", huge),
      ]),
    )
    as "quoted JSON exceeds the bound"
  assert workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([pair("key", msgpack.StringValue("main/huge"))]),
    )
    == framing.CapOk(
      msgpack.MapValue([pair("found", msgpack.BoolValue(False))]),
    )
  let plain = config_for(idle_broker())
  let assert framing.CapErr(code: "unsupported_cap", ..) =
    workspace_note_call(plain, "notes.put", msgpack.MapValue([]))
    as "an absent door cannot write"
}

pub fn note_put_cannot_select_another_writers_namespace_test() {
  let config =
    codemode.serving(
      config_for(idle_broker()),
      codemode.WorkspaceOnly,
      over: start_runtime().seam,
    )
  assert workspace_note_call(
      config,
      "notes.put",
      msgpack.MapValue([
        pair("key", msgpack.StringValue("other/analysis")),
        pair("value", msgpack.NilValue),
        pair("strand", msgpack.StringValue("other")),
      ]),
    )
    == framing.CapOk(msgpack.NilValue)
  assert workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([pair("key", msgpack.StringValue("other/analysis"))]),
    )
    == framing.CapOk(
      msgpack.MapValue([pair("found", msgpack.BoolValue(False))]),
    )
  assert workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([pair("key", msgpack.StringValue("main/other/analysis"))]),
    )
    == framing.CapOk(
      msgpack.MapValue([
        pair("found", msgpack.BoolValue(True)),
        pair("value", msgpack.NilValue),
      ]),
    )
}

pub fn an_accepted_note_at_the_size_limit_remains_readable_test() {
  let config =
    codemode.serving(
      config_for(idle_broker()),
      codemode.WorkspaceOnly,
      over: start_runtime().seam,
    )
  let value = msgpack.StringValue(string.repeat("x", notes.max_bytes - 2))
  assert workspace_note_call(
      config,
      "notes.put",
      msgpack.MapValue([
        pair("key", msgpack.StringValue("limit")),
        pair("value", value),
      ]),
    )
    == framing.CapOk(msgpack.NilValue)
  assert workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([pair("key", msgpack.StringValue("main/limit"))]),
    )
    == framing.CapOk(
      msgpack.MapValue([
        pair("found", msgpack.BoolValue(True)),
        pair("value", value),
      ]),
    )
}

pub fn maximum_note_keys_round_trip_through_list_get_and_virtual_reads_test() {
  let config =
    codemode.serving(
      config_for(idle_broker()),
      codemode.WorkspaceOnly,
      over: start_runtime().seam,
    )
  let key = string.repeat("k", 128)
  let qualified = "main/" <> key
  assert workspace_note_call(
      config,
      "notes.put",
      msgpack.MapValue([
        pair("key", msgpack.StringValue(key)),
        pair("value", msgpack.IntValue(7)),
      ]),
    )
    == framing.CapOk(msgpack.NilValue)
  let assert framing.CapOk(msgpack.MapValue(fields)) =
    workspace_note_call(
      config,
      "notes.list",
      msgpack.MapValue([pair("prefix", msgpack.NilValue)]),
    )
    as "the shared listing must return the accepted note"
  let assert Ok(msgpack.ArrayValue([msgpack.MapValue(cell)])) =
    list.key_find(fields, msgpack.StringValue("notes"))
    as "the sole returned cell must be reusable"
  let assert Ok(msgpack.StringValue(returned)) =
    list.key_find(cell, msgpack.StringValue("key"))
    as "list returns the relative key"
  assert returned == qualified
  assert workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([pair("key", msgpack.StringValue(returned))]),
    )
    == framing.CapOk(
      msgpack.MapValue([
        pair("found", msgpack.BoolValue(True)),
        pair("value", msgpack.IntValue(7)),
      ]),
    )
  assert workspace_note_call(
      config,
      "notes.read",
      msgpack.MapValue([pair("key", msgpack.StringValue(returned))]),
    )
    == framing.CapOk(
      msgpack.MapValue([pair("contents", msgpack.StringValue("7"))]),
    )
  let assert framing.CapErr(code: "invalid_argument", ..) =
    workspace_note_call(
      config,
      "notes.get",
      msgpack.MapValue([
        pair("key", msgpack.StringValue(string.repeat("x", 4097))),
      ]),
    )
    as "read prefixes remain bounded"
}

pub fn note_reads_propagate_storage_failures_instead_of_absence_test() {
  let faults = [
    storage.BackendFault("injected blackboard read failure"),
    storage.CorruptRow(corruption.report(
      at: "notes regression",
      on: "agent/main/saved",
      expected: "valid JSON",
      context: "bad stored bytes",
    )),
  ]
  list.each(faults, fn(fault) {
    list.each(["notes.get", "notes.list", "notes.read"], fn(cap) {
      let live =
        start_runtime_over(fn(sess) {
          let store =
            storage.Storage(
              ..sess.store,
              list_registers: fn(handle, namespace, prefix) {
                case prefix {
                  Some(key) if key == "agent/" || key == "agent/main/saved" ->
                    Error(fault)
                  _ -> sess.store.list_registers(handle, namespace, prefix)
                }
              },
            )
          session.Session(..sess, store:)
        })
      let config =
        codemode.serving(
          config_for(idle_broker()),
          codemode.WorkspaceOnly,
          over: live.seam,
        )
      assert workspace_note_call(
          config,
          "notes.put",
          msgpack.MapValue([
            pair("key", msgpack.StringValue("saved")),
            pair("value", msgpack.IntValue(7)),
          ]),
        )
        == framing.CapOk(msgpack.NilValue)
      let assert framing.CapErr(code: "plane_failed", message: reason) =
        workspace_note_call(
          config,
          cap,
          msgpack.MapValue([
            pair("key", msgpack.StringValue("main/saved")),
            pair("prefix", msgpack.NilValue),
          ]),
        )
        as "a failed durable read must not look like an absent note"
      assert reason != ""
    })
  })
}

fn peer_wiring() -> peers.Wiring {
  peers.Wiring(
    own: peer_mail.Endpoint("test-session", fn(command) {
      case command {
        peer_mail.Inbox(strand, _, _) -> Ok(json.String(strand))
        _ -> Error("only inbox is used by this fixture")
      }
    }),
    metadata: json.Object([]),
    directory: None,
  )
}

fn config_with_entropy_payload(
  base: codemode.Config,
  words: Int,
) -> codemode.Config {
  let payload = list.repeat(#("payload", "payload"), words)
  codemode.Config(..base, entropy: fn(_bytes) { <<list.length(payload):64>> })
}

/// Peer composition retains the preceding router rather than its whole host.
pub fn peer_router_does_not_copy_unrelated_host_configuration_test() {
  let broker_actor = idle_broker()
  let base = config_for(broker_actor)
  let light = config_with_entropy_payload(base, 1)
  let heavy = config_with_entropy_payload(base, 4096)
  let small = serve.with_code_mode_peers(light, peer_wiring())
  let large = serve.with_code_mode_peers(heavy, peer_wiring())

  // Entropy remains in the host configuration, where satellite launch needs it.
  assert ffi_memory.flat_words(heavy) > ffi_memory.flat_words(light) + 8192
  assert ffi_memory.flat_words(large) > ffi_memory.flat_words(small) + 8192
  assert ffi_memory.flat_words(large.wrap_router)
    == ffi_memory.flat_words(small.wrap_router)
  let _ = broker.stop(broker_actor)
}

/// Existing host wrapping runs first; peer calls intercept before its fallback.
pub fn peer_router_preserves_wrapping_order_and_caller_strand_test() {
  let broker_actor = idle_broker()
  let order = process.new_subject()
  let original =
    codemode.Config(
      ..config_for(broker_actor),
      wrap_router: fn(request: codemode_tool.Request, fallback) {
        process.send(order, "wrap:" <> request.strand)
        fn(cap) {
          process.send(order, "original dispatch")
          fallback(cap)
        }
      },
    )
  let config = serve.with_code_mode_peers(original, peer_wiring())
  let request = request_for("peer-order")
  let router =
    config.wrap_router(request, fn(_cap) {
      process.send(order, "fallback")
      Error(satellite.CapDenial("fixture", "fallback marker"))
    })
  assert process.receive(order, 0) == Ok("wrap:" <> request.strand)
  let cap =
    satellite.CapRequest(
      cap: "peer.inbox",
      args: msgpack.MapValue([
        #(msgpack.StringValue("after"), msgpack.StringValue("")),
        #(msgpack.StringValue("limit"), msgpack.IntValue(1)),
      ]),
      identity: identity.run_phase(identity.for_execution(
        op_id: request.op_id,
        step_id: request.step_id,
        budget: budget.Budget(4, 9_000_000),
      )),
      base_policy: request.base_policy,
      demand: request.demand,
      env: [],
      cwd: request.workspace,
      ordinal: 0,
    )
  let assert Ok(satellite.ServedHere(answer)) = router(cap)
    as "the peer router intercepts its own capability"
  assert answer()
    == framing.CapOk(
      msgpack.StringValue(json.to_string(json.String(request.strand))),
    )
  assert process.receive(order, 0) == Error(Nil)

  // Other capabilities keep both the original dispatch and fallback result.
  assert router(satellite.CapRequest(..cap, cap: "fixture.other"))
    == Error(satellite.CapDenial("fixture", "fallback marker"))
  assert process.receive(order, 0) == Ok("original dispatch")
  assert process.receive(order, 0) == Ok("fallback")
  let _ = broker.stop(broker_actor)
}

/// A detached worker copies its host configuration once at admission.
pub fn async_worker_does_not_duplicate_unrelated_configuration_test() {
  let broker_actor = idle_broker()
  let base = config_for(broker_actor)
  let light = config_with_entropy_payload(base, 1)
  let heavy = config_with_entropy_payload(base, 4096)
  let admitted = process.new_subject()
  let name = addresses.new()
  let assert Ok(service) =
    actor.new(Nil)
    |> actor.on_message(fn(state, message) {
      case message {
        async_runs.Launch(record:, work:, reply:) -> {
          // Measure the actual admission message after its process copy. No
          // compiler or satellite runs, and no private closure layout is read.
          process.send(admitted, #(record, ffi_memory.flat_words(work)))
          process.send(reply, Ok(json.Null))
          actor.continue(state)
        }
        _ -> actor.stop_abnormal("unexpected async fixture message")
      }
    })
    |> actor.addressed(name)
    |> actor.start
    as "the admission observer must start"
  let agents = agency.default_config(addresses.new(), clock.fixed(at: 1000))
  let request = request_for("detached-copy")

  list.each([light, heavy], fn(config) {
    let assert Some(background) =
      async_codemode.seam(config, name, agents).background
      as "the detached seam must be available"
    assert background.launch(request) == Ok(json.Null)
  })
  let assert Ok(#(small_record, small_words)) = process.receive(admitted, 1000)
    as "the light worker must reach admission"
  let assert Ok(#(large_record, large_words)) = process.receive(admitted, 1000)
    as "the heavy worker must reach admission"

  // Unrelated entropy remains needed by the worker's configuration. Its
  // router wrapper must not introduce a second copy of that same payload.
  let payload_words =
    ffi_memory.flat_words(heavy) - ffi_memory.flat_words(light)
  assert payload_words > 8192
  assert large_words - small_words == payload_words
  assert small_record == large_record
  assert small_record.deadline_ms == 61_000
  assert small_record.operation == request.op_id
  assert small_record.strand == request.strand
  assert small_record.step == "async/" <> small_record.id

  process.unlink(service.pid)
  process.kill(service.pid)
  let _ = broker.stop(broker_actor)
}

// The trusted entry is exercised with the actual custody constructor rather
// than a reconstructed key. Provider metadata and canonical arguments remain
// on the original Invocation while this adapter validates its coordinates.
fn managed_invocation(
  request: codemode_tool.Request,
) -> tool_custody.Invocation {
  let generator = ids.generator(clock.fixed(1000), 711)
  let #(session, generator) = ids.mint_session(generator)
  let #(result_entry, _) = ids.mint_entry(generator)
  let arguments = json.Object([#("source", json.String(request.source))])
  let run =
    effects.ToolRun(
      operation: request.op_id,
      step_id: request.step_id,
      source_index: request.source_index,
      result_entry:,
      strand: request.strand,
      call: message.ToolCall(
        id: "original-code-mode",
        name: "code_mode",
        arguments:,
        thought_signature: Some("original-signature"),
        namespace: None,
      ),
      arguments:,
      replay: operation.ReplayNever,
      grants: [],
    )
  let assert Ok(invocation) =
    tool_custody.invocation(session, <<"original-authority">>, run)
    as "Actual runtime metadata constructs the original retained Invocation."
  invocation
}

fn managed_owner(seen: Subject(dispatch.Dispatch)) -> broker.Broker {
  let assert Ok(owner) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(start: fn(call) {
        process.send(seen, call)
        Error(dispatch.NotStarted)
      }),
    )
    as "The production broker is available for the managed entry."
  owner
}

pub fn managed_coordinates_refuse_before_workspace_setup_or_dispatch_test() {
  let request = request_at("original-tools", 3)
  let invocation = managed_invocation(request)
  let seen = process.new_subject()
  let owner = managed_owner(seen)
  let config =
    codemode.Config(
      ..config_for(owner),
      work_root: "/dev/null/managed-must-not-create",
      socket_root: None,
    )
  list.each(
    [
      codemode_tool.Request(..request, op_id: an_op(99)),
      codemode_tool.Request(..request, step_id: "different-step"),
      codemode_tool.Request(..request, source_index: 4),
    ],
    fn(changed) {
      assert codemode.execute_managed(config, invocation.key, changed)
        == Error(
          "managed code-mode request does not match its original invocation",
        )
    },
  )
  assert process.receive(seen, 50) == Error(Nil)
  assert simplifile.is_directory(config.work_root) != Ok(True)
  broker.stop(owner)
}

pub fn managed_invocation_reaches_real_compile_clearance_with_original_key_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "The fixture has its own checkout directory."
  let root = here <> "/build/managed-entry-fixture"
  let seed_root = root <> "/seed"
  let assert Ok(Nil) =
    seed.prepare(
      root: seed_root,
      vendored: [],
      dependencies: compile.default_dependencies(),
    )
    as "The production seed writer pins this entry's dependency table."
  let assert Ok(Nil) = simplifile.create_directory_all(seed_root <> "/vendor")
    as "The seed has the vendored clone directory."
  let assert Ok(Nil) =
    simplifile.create_directory_all(seed_root <> "/build/packages")
    as "The seed has the cache layout the builder verifies."
  let assert Ok(Nil) = simplifile.write(seed_root <> "/manifest.toml", "")
    as "The recording refusal does not execute a compiler."
  let assert Ok(Nil) =
    simplifile.write(seed_root <> "/build/packages/packages.toml", "")
    as "The builder can proceed through actual clone preparation."
  let request =
    codemode_tool.Request(
      ..request_at("original-tools", 3),
      source: "import cap/report\npub fn main() { report.text(\"managed\") }",
      base_policy: policy.SandboxPolicy(
        ..policy.workspace_default(root),
        readable_roots: ["/"],
      ),
    )
  let invocation = managed_invocation(request)
  let seen = process.new_subject()
  let owner = managed_owner(seen)
  let config =
    codemode.Config(
      ..config_for(owner),
      work_root: root <> "/work",
      socket_root: Some("/private/tmp/loom-managed-entry-sockets"),
      seed_root:,
    )
  let assert Ok(execution) =
    codemode.execute_managed(config, invocation.key, request)
    as "The original coordinates admit trusted managed execution."
  let assert codemode_tool.CompileFailed(_) = execution.result
    as "The controlled dispatcher refuses after observing actual clearance."
  let assert Ok(call) = process.receive(seen, 2000)
    as "Client entry must reach the real builder and broker dispatcher."
  let assert Some(origin) = call.context.origin
    as "Original Invocation provenance survives every production adapter."
  assert remote_tool.child_tool(origin) == Ok(invocation.key)
  assert remote_tool.child_role(origin) == Ok(remote_tool.CompileCommand)
  assert call.context.operation == request.op_id
  assert call.context.step == request.step_id
  assert call.deadline_ms == 1000 + request.within_ms
  assert remote_tool.source_index(invocation.key) == 3
  broker.stop(owner)
}

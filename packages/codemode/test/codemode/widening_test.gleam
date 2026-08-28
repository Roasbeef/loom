//// What an approved escalation widens, and — the half that matters more
//// — what it does not.
////
//// Issue #24: the four clearances the pipeline makes used to pass empty
//// grants, so an approval reaching code mode changed nothing. These tests
//// are about where the grants now arrive, where they are refused, and
//// what the record says afterwards. `codemode/identity` is the one place
//// that decides all three, so most of the assertions here are really
//// assertions about `build_phase` and `run_phase`.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import broker/token
import codemode/build
import codemode/codemode
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/launch
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/string
import simplifile
import support/fake_helper
import support/satellite_peer.{type PeerCtx}

const t = 1_700_000_000_000

// One grant, used everywhere below, chosen because it is the one an
// operator would actually be asked about here: a satellite node cannot
// find its cap channel unless the composed policy names `LOOM_CAP_SOCK`,
// so a session base that omits it refuses every code-mode execution until
// somebody approves exactly this.
fn approved() -> List(policy.Grant) {
  [policy.GrantEnv(name: launch.sock_env)]
}

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 11)
  let #(op, _) = ids.mint_op(generator)
  op
}

fn pooled() -> budget.Budget {
  budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)
}

fn plain_identity() -> identity.ExecIdentity {
  identity.for_execution(op_id(), step_id: "step-1", budget: pooled())
}

fn widened_identity() -> identity.ExecIdentity {
  identity.widened_by(plain_identity(), grants: approved())
}

// --- where the grants land ------------------------------------------------

pub fn the_run_phase_carries_the_approved_grants_test() {
  assert identity.grants(identity.run_phase(widened_identity())) == approved()
}

pub fn the_build_phase_never_carries_them_test() {
  // The whole of question two, as one line. `build_phase` drops the
  // execution's approval rather than forwarding it, so there is no
  // widened build phase to hand a clearance — not a build clearance that
  // remembers to pass `[]`.
  assert identity.grants(identity.build_phase(widened_identity())) == []
}

pub fn an_unapproved_execution_carries_nothing_test() {
  assert identity.grants(identity.run_phase(plain_identity())) == []
  assert identity.grants(identity.build_phase(plain_identity())) == []
}

pub fn a_widening_opens_no_extra_ledger_test() {
  // Grants are consent, not accounting: they must not move the pair the
  // broker keys a pooled ledger by, or an approval would buy a second
  // `max_outstanding` cap along with the widening.
  assert identity.ledger_keys(widened_identity())
    == identity.ledger_keys(plain_identity())
}

// --- the clearances themselves --------------------------------------------

pub fn the_build_clearance_is_never_widened_test() {
  let spec =
    build.build_call(
      build_config(),
      identity.build_phase(widened_identity()),
      "/work/build",
    )
  // Composition applies grants *after* the meet, so a grant arriving here
  // would be able to undo the build's own `network: NetworkOff`
  // requirement — which is the one property a hermetic build has.
  assert spec.grants == []
  assert spec.requirements.network == policy.NetworkOff
}

pub fn the_node_clearance_carries_the_approved_grants_test() {
  let spec = launch_spec("/work", widened_identity())
  let call =
    launch.node_call(launch_config(), spec, launch.node_requirements(spec, t))
  assert call.grants == approved()
}

pub fn an_unapproved_node_clearance_carries_none_test() {
  let spec = launch_spec("/work", plain_identity())
  let call =
    launch.node_call(launch_config(), spec, launch.node_requirements(spec, t))
  assert call.grants == []
}

pub fn a_routed_capability_call_carries_the_approved_grants_test() {
  // A `cap_call` the running program makes is the program's own
  // execution, so it composes what the run phase carries. The router
  // reads them off the identity it was handed rather than holding a list
  // of its own.
  let assert Ok(satellite.ClearedCall(spec:, render: _)) =
    satellite.default_router(cap_request(widened_identity()))
    as "proc.run must route to a jailed clearance"
  assert spec.grants == approved()

  let assert Ok(satellite.ClearedCall(spec: unwidened, render: _)) =
    satellite.default_router(cap_request(plain_identity()))
    as "proc.run must route to a jailed clearance"
  assert unwidened.grants == []
}

// --- the launch policy composition ---------------------------------------

pub fn a_base_that_cannot_host_a_node_is_refused_test() {
  // The site issue #24 names. `launch` composes `base ⊕ requirements ⊕
  // grants` before it does anything else and refuses in band with the
  // exact shortfall; a base whose env allowlist omits `LOOM_CAP_SOCK`
  // cannot host a satellite, because the node would come up unable to
  // find the channel it exists to speak on.
  let assert Error(reason) = narrowed_launch("refused", plain_identity())
    as "a base missing the cap-socket env name must not host a node"
  assert string.contains(reason, "the session base cannot host a satellite")
  assert string.contains(reason, launch.sock_env)
}

pub fn the_grant_composes_at_the_launch_policy_test() {
  // The same base, the same requirements, one approved grant — and the
  // launch that was refused a moment ago goes through: socket bound,
  // node dispatched, connection handed back. Nothing else changed, so
  // the grant composing at `launch`'s policy check is the only thing
  // that can have made the difference.
  assert narrowed_launch("granted", widened_identity()) == Ok(Nil)
}

pub fn a_grant_for_something_else_widens_nothing_here_test() {
  // An approval carries exactly the grants a human chose, and composition
  // is the only place they act. A grant that does not cover this
  // shortfall leaves the refusal exactly where it was — which is what
  // keeps a yes given for one want from being spendable on another.
  let elsewhere =
    identity.widened_by(plain_identity(), grants: [
      policy.GrantEnv(name: "SOMETHING_ELSE"),
    ])
  let assert Error(reason) = narrowed_launch("elsewhere", elsewhere)
    as "an unrelated grant must not host a node"
  assert string.contains(reason, "the session base cannot host a satellite")
  assert string.contains(reason, launch.sock_env)
}

// --- what the record says -------------------------------------------------

pub fn a_widened_execution_says_so_in_the_record_test() {
  let dir = fresh_dir("widened")
  let execution =
    codemode.execute(program(), pipeline_config(dir, widened_identity()))
  let assert codemode.Ran(..) = execution.outcome
    as "the faked pipeline must run to an outcome"
  assert execution.widening == enforcement.Widened(grants: approved())
  // Legible without knowing the grant vocabulary, which is what an
  // operator reading a record actually has.
  assert list.map(approved(), enforcement.grant_label)
    == ["env=" <> launch.sock_env]
}

pub fn an_unapproved_execution_reports_no_widening_test() {
  let dir = fresh_dir("plain")
  let execution =
    codemode.execute(program(), pipeline_config(dir, plain_identity()))
  let assert codemode.Ran(..) = execution.outcome
    as "the faked pipeline must run to an outcome"
  let assert enforcement.NotWidened(reason:) = execution.widening
    as "an execution nobody approved must not read as widened"
  assert string.contains(reason, "no approved escalation")
}

pub fn an_approval_the_pipeline_never_reached_reads_as_unspent_test() {
  // A human answered a question and the program never got to the door
  // the answer opened. That is a different fact from "nobody approved
  // anything", and an operator auditing approvals needs to tell them
  // apart: this one has an approval whose fate they are entitled to ask
  // about.
  let dir = fresh_dir("unspent")
  let source =
    "@external(erlang, \"os\", \"cmd\")\npub fn run(c: String) -> String\n"
  let execution =
    codemode.execute(source, pipeline_config(dir, widened_identity()))
  let assert codemode.VetRejected(_) = execution.outcome
    as "an @external must be refused by vetting"
  let assert enforcement.NotWidened(reason:) = execution.widening
    as "nothing composed the grants, so nothing was widened"
  assert string.contains(reason, "an approved escalation was attributed")
  assert string.contains(reason, "vetting refused")
}

pub fn a_failed_build_never_spends_the_approval_test() {
  let dir = fresh_dir("build-fail")
  let failing = fn(_phase, _root, _generated) {
    compile.Built(
      result: Error(compile.BuildRejected(diagnostics: "type error")),
      enforcement: enforcement.Reported(entries: ["bwrap"], degraded: False),
    )
  }
  let config =
    codemode.ExecConfig(
      ..pipeline_config(dir, widened_identity()),
      compile: compile.CompileConfig(
        build_root: dir <> "/build",
        dependencies: compile.default_dependencies(),
        generated: [],
        build: failing,
      ),
    )
  let execution = codemode.execute(program(), config)
  let assert codemode.CompileFailed(_) = execution.outcome
    as "the failing builder must settle the execution"
  let assert enforcement.NotWidened(reason:) = execution.widening
    as "the hermetic build is never widened, so it can spend nothing"
  assert string.contains(reason, "never") || string.contains(reason, "is never")
}

// --- fixtures -------------------------------------------------------------

fn program() -> String {
  "import cap/fs\npub fn main() { fs.read(\"x\") }\n"
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/widen-" <> name
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

// The session base an approval is asked to widen: everything a satellite
// needs except the one environment name that lets it find its socket.
fn narrowed_base(root: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(root),
    readable_roots: ["/"],
    env_allow: ["PATH", launch.token_env],
  )
}

fn started_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Ok(fake_helper.start_helper(fake_helper.EchoNow)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the fake broker must start"
  started
}

fn build_config() -> build.BuildConfig {
  build.BuildConfig(
    broker: started_broker(),
    seed_root: "/seed",
    gleam_path: "/usr/bin/gleam",
    base_policy: policy.workspace_default("/work"),
    toolchain_roots: ["/"],
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    dependencies: compile.default_dependencies(),
    timeout_ms: 1000,
  )
}

fn launch_config() -> launch.LaunchConfig {
  launch.LaunchConfig(
    broker: started_broker(),
    clock: clock.fixed(at: t),
    erl_path: "/usr/bin/erl",
    demand: exec.BestEffort,
    accept_timeout_ms: 1000,
  )
}

fn launch_spec(
  root: String,
  id: identity.ExecIdentity,
) -> satellite.LaunchSpec {
  satellite.LaunchSpec(
    artifact: compile.Artifact(
      build_root: root,
      beam_dir: root <> "/ebin",
      entry_module: compile.entry_module,
      manifest_hash: "sha256-beef",
    ),
    token_path: root <> "/token",
    cap_socket_path: root <> "/s",
    identity: identity.run_phase(id),
    base_policy: narrowed_base(root),
    env: [#("PATH", "/usr/bin")],
    cwd: root,
    wire: process.new_subject(),
  )
}

// Runs the production launcher against a base an approval is meant to
// widen, and answers one question: did the launch policy composition turn
// this execution away, or did it not? A launch that got through is torn
// down again, so a passing test leaves no socket bound and no node behind.
fn narrowed_launch(
  name: String,
  id: identity.ExecIdentity,
) -> Result(Nil, String) {
  let root = fresh_dir(name)
  case launch.launcher(launch_config())(launch_spec(root, id)) {
    Ok(connection) -> {
      let _report = connection.destroy()
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

fn cap_request(id: identity.ExecIdentity) -> satellite.CapRequest {
  satellite.CapRequest(
    cap: "proc.run",
    args: msgpack.MapValue([
      #(
        msgpack.StringValue("argv"),
        msgpack.ArrayValue([msgpack.StringValue("/bin/echo")]),
      ),
    ]),
    identity: identity.run_phase(id),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    ordinal: 0,
  )
}

// The whole pipeline with the two expensive stages faked, so the report
// assertions cost milliseconds rather than a hermetic build.
fn pipeline_config(
  dir: String,
  id: identity.ExecIdentity,
) -> codemode.ExecConfig {
  codemode.ExecConfig(
    vet_policy: vet_policy.default(),
    compile: compile.CompileConfig(
      build_root: dir <> "/build",
      dependencies: compile.default_dependencies(),
      generated: [],
      build: ok_builder,
    ),
    broker: started_broker(),
    identity: id,
    satellite: satellite.SatelliteConfig(
      base_policy: policy.workspace_default("/work"),
      demand: exec.BestEffort,
      env: [#("PATH", "/usr/bin")],
      cwd: "/work",
      cap_socket_path: dir <> "/sock",
      entropy: token.production_entropy(),
      clock: clock.fixed(at: t),
      write_token_file: satellite.private_token_writer(dir),
      unlink_token_file: satellite.unlink_token_file,
      router: satellite.default_router,
      ceilings: [],
      call_timeout_ms: 3000,
    ),
    launch: satellite_peer.launcher(finish_peer),
  )
}

fn ok_builder(
  _phase: identity.PhaseIdentity,
  root: String,
  _generated: List(#(String, String)),
) -> compile.Built {
  compile.Built(
    result: Ok(compile.BuildProducts(
      beam_dir: root <> "/ebin",
      manifest_hash: "beef",
    )),
    enforcement: enforcement.Reported(entries: ["bwrap"], degraded: False),
  )
}

fn finish_peer(ctx: PeerCtx) -> Nil {
  satellite_peer.send_outcome(ctx, msgpack.StringValue("widened"))
}

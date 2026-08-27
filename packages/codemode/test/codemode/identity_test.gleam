//// Identity-threading tests: how many pooled ledgers one code-mode
//// execution can open, and where that number comes from.
////
//// # What can and cannot be tested here
////
//// The property this refactor exists to install is a *type* property —
//// "no caller can mint a second identity for one execution" — and Gleam
//// has no compile-fail test harness, so the half of it that is enforced
//// by the compiler cannot be asserted at run time. Faking it with a
//// runtime check that only re-reads what the code already does would be
//// worse than saying so, so it is stated here instead, and the reader can
//// verify each clause by opening the named type:
////
//// - `identity.ExecIdentity` and `identity.PhaseIdentity` are both
////   `pub opaque`. `for_execution` is the only constructor of the first,
////   and `build_phase` / `run_phase` — each of which *takes* an
////   `ExecIdentity` — are the only constructors of the second. There is no
////   expression that produces a phase identity without a parent.
//// - `codemode.ExecConfig` has exactly one field of identity type, and
////   `compile.CompileConfig`, `build.BuildConfig`, `satellite.SatelliteConfig`
////   and `launch.LaunchConfig` have none: no operation, no step, no
////   budget. A caller has nowhere to write a second set of coordinates,
////   and `codemode.execute` derives both phases from the one field. Add an
////   `op_id` back to any of those records and this file still passes —
////   which is exactly why the argument is written out rather than
////   asserted.
////
//// What *is* asserted below is the half that could regress silently: that
//// the derivation is total and bounded (`ledger_keys` is a function of the
//// identity alone, and answers one or two), and that a whole execution
//// really does clear every one of its stages under those keys and no
//// others — observed at the three injected seams the pipeline hands
//// identity to (the builder, the launcher, the cap router), which is where
//// a future caller such as the orchestration seam would plug in.

import broker/broker
import broker/budget.{type Budget}
import broker/exec
import broker/policy
import broker/token
import codemode/codemode
import codemode/compile
import codemode/enforcement
import codemode/identity.{type ExecIdentity}
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/ids.{type OpId}
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import simplifile
import support/fake_helper
import support/satellite_peer.{type PeerCtx}

const t = 1_700_000_000_000

fn op_id() -> OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 23)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

fn pooled() -> Budget {
  budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)
}

fn shared() -> ExecIdentity {
  identity.for_execution(op_id: op_id(), step_id: "step-1", budget: pooled())
}

// --- the derivation is bounded by the type -------------------------------

pub fn a_plain_execution_opens_exactly_one_ledger_test() {
  let id = shared()
  // Both phases resolve to the execution's own key, so build, node and
  // every capability call share one ledger and one wall deadline — the
  // pooling `docs/adr/005-budget-pooling-granularity.md` fixes.
  assert identity.ledger_key(identity.build_phase(id))
    == identity.ledger_key(identity.run_phase(id))
  assert identity.ledger_keys(id) == [#(op_id(), "step-1")]
}

pub fn a_separately_accounted_build_opens_exactly_two_test() {
  let id = identity.with_own_build_ledger(shared())
  // The build's step is *derived* — the same operation, the `-build`
  // sub-step — so `broker.abort` still reaches both, and the second key is
  // not something a caller wrote.
  assert identity.op_id(identity.build_phase(id)) == op_id()
  assert identity.step_id(identity.build_phase(id))
    == "step-1" <> identity.build_suffix
  assert identity.step_id(identity.run_phase(id)) == "step-1"
  assert identity.ledger_keys(id)
    == [#(op_id(), "step-1-build"), #(op_id(), "step-1")]
}

pub fn the_phases_are_named_in_the_type_test() {
  assert identity.phase(identity.build_phase(shared())) == identity.Build
  assert identity.phase(identity.run_phase(shared())) == identity.Run
}

pub fn every_phase_draws_on_the_one_parent_budget_test() {
  let id = identity.with_own_build_ledger(shared())
  // Even the separately accounted build reserves against the execution's
  // own budget: separate ledger, same ceiling — never a second budget the
  // caller could raise on one phase alone.
  assert identity.pooled_budget(identity.build_phase(id)) == pooled()
  assert identity.pooled_budget(identity.run_phase(id)) == pooled()
}

pub fn re_budgeting_cannot_add_a_ledger_test() {
  let id = shared()
  let short = budget.Budget(max_outstanding: 2, deadline_ms: t + 500)
  let tightened = identity.under_budget(id, budget: short)
  // The one derivation that changes a phase's budget leaves the keys
  // alone, so it can tighten a deadline and never widen the ledger count.
  assert identity.ledger_keys(tightened) == identity.ledger_keys(id)
  assert identity.pooled_budget(identity.run_phase(tightened)) == short
}

// --- the pipeline clears under those keys and no others ------------------
//
// The three seams below are where a caller injects code into the pipeline,
// and therefore where a second identity would enter if one could. Each
// records the `{op_id, step_id}` it was handed; the assertion is that the
// distinct set matches what `ledger_keys` predicted from the identity value
// alone, before anything ran.

pub fn one_execution_clears_only_under_its_derived_keys_test() {
  let observed = observe_execution(shared())
  assert observed == identity.ledger_keys(shared())
  // Not vacuous: all three seams ran, so this is three observations
  // collapsing onto one key rather than one seam being missed.
  assert list.length(observed) == 1
}

pub fn a_separate_build_ledger_is_the_only_way_to_a_second_key_test() {
  let id = identity.with_own_build_ledger(shared())
  let observed = observe_execution(id)
  assert observed == identity.ledger_keys(id)
  assert list.length(observed) == 2
}

// Runs one whole execution with recording seams and returns the distinct
// `{op_id, step_id}` pairs the pipeline actually cleared under, in the
// order the pipeline reached them.
fn observe_execution(id: ExecIdentity) -> List(#(OpId, String)) {
  let dir =
    fresh_dir(case identity.ledger_keys(id) {
      [_one] -> "shared"
      _ -> "split"
    })
  let seen = process.new_subject()
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Ok(fake_helper.start_helper(fake_helper.EchoNow)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  let config =
    codemode.ExecConfig(
      vet_policy: vet_policy.default(),
      compile: compile.CompileConfig(
        build_root: dir <> "/build",
        dependencies: compile.default_dependencies(),
        build: recording_builder(seen),
      ),
      broker: started,
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
        router: recording_router(seen),
        call_timeout_ms: 3000,
      ),
      launch: recording_launcher(seen),
    )
  let source = "import cap/report\npub fn main() { report.text(\"x\") }\n"
  let execution = codemode.execute(source, config)
  let assert codemode.Ran(..) = execution.outcome
    as "the observed execution must reach the run stage"
  broker.stop(started)
  drain(seen, [])
}

fn recording_builder(seen: Subject(#(OpId, String))) -> compile.Builder {
  fn(phase, root) {
    process.send(seen, identity.ledger_key(phase))
    compile.Built(
      result: Ok(compile.BuildProducts(
        beam_dir: root <> "/ebin",
        manifest_hash: "beef",
      )),
      enforcement: enforcement.Reported(entries: ["bwrap"], degraded: False),
    )
  }
}

fn recording_launcher(seen: Subject(#(OpId, String))) -> satellite.Launcher {
  fn(spec: satellite.LaunchSpec) {
    process.send(seen, identity.ledger_key(spec.identity))
    satellite_peer.launcher(calling_peer)(spec)
  }
}

fn recording_router(seen: Subject(#(OpId, String))) -> satellite.CapRouter {
  fn(request: satellite.CapRequest) {
    process.send(seen, identity.ledger_key(request.identity))
    satellite.default_router(request)
  }
}

// A peer that makes one real capability call — so the router seam is
// genuinely exercised — and then reports an outcome.
fn calling_peer(ctx: PeerCtx) -> Nil {
  satellite_peer.send_proc_run(ctx, ctx.token, 1, ["/bin/echo", "hi"])
  let _settled = satellite_peer.collect_results(ctx, 1, 3000)
  satellite_peer.send_outcome(ctx, msgpack.StringValue("observed"))
}

// Drains everything the seams recorded, preserving first-seen order and
// dropping repeats: the question is which ledgers were touched, not how
// many times each was.
fn drain(
  seen: Subject(#(OpId, String)),
  acc: List(#(OpId, String)),
) -> List(#(OpId, String)) {
  case process.receive(seen, 200) {
    Error(Nil) -> list.reverse(acc) |> list.unique
    Ok(key) -> drain(seen, [key, ..acc])
  }
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/identity-" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

// --- the derived step is what actually reaches the broker ----------------

pub fn the_derived_build_step_is_what_the_clearance_carries_test() {
  // The `-build` suffix is one string, in one place. A reader tracing a
  // `-build` ledger in a broker log lands on `identity.build_suffix` and
  // nothing else.
  let id = identity.with_own_build_ledger(shared())
  let #(_op, step) = identity.ledger_key(identity.build_phase(id))
  assert string.ends_with(step, identity.build_suffix)
  assert string.starts_with(step, "step-1")
}

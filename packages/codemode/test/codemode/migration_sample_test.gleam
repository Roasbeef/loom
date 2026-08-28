//// The code-mode **migration sample** — M4's named acceptance criterion.
////
//// `docs/examples/stale_symbol_sweep.gleam` is the readable artifact: a
//// program of the kind a model writes instead of a sequence of tool calls,
//// retiring a symbol across three packages. This suite reads *that file,
//// verbatim* and puts it through the real pipeline — real vetting, a real
//// hermetic `gleam build` in a network-off jail, a real `erl` satellite, a
//// real AF_UNIX cap channel, and five real jailed processes behind
//// `proc.run` — against a fixture repository laid out under the rig's
//// workspace, and asserts on the structured outcome that comes back.
////
//// Reading the file rather than restating the source inline is deliberate:
//// the documented artifact and the executed one cannot drift, and a sample
//// edited into something that no longer vets, compiles, or runs fails here.
//// `client/test/client/catalog_test.gleam` parses `docs/examples/loom.toml`
//// the same way.
////
//// # What is asserted, and why none of it is free
////
//// The outcome line alone would pass whether or not any of code mode's
//// concurrency claims held, so the fixture (`support/sample_repo`) is
//// instrumented and the assertions read the instrumentation back:
////
//// - **Fan-out is really concurrent.** The last sweep to *start* did so
////   before the first sweep *finished*, so all three were running at once.
////   Three sequential runs cannot produce overlapping intervals.
//// - **Order preservation is really a property.** The sweeps complete in
////   the exact reverse of the order the program lists them in, and the
////   outcome still reports them in input order. If `parallel_map` returned
////   completion order the reported counts would be reversed too, and the
////   fixture's per-package counts are distinct so that reversal is visible.
//// - **Race cancellation is really a kill.** The losing build strategy
////   ticks a file every half second for thirty seconds. The race is decided
////   about a third of a second in, and the program then spends three more
////   seconds sweeping; a loser that was merely abandoned would tick its way
////   through all of it. The assertion is an upper bound on the tick count,
////   and a lower bound too — a loser that never started would prove nothing.
////
//// # Degraded-mode honesty
////
//// The concurrency claims above hold on any kernel: they are about the
//// BEAM, the broker, and real OS processes, none of which need a jail
//// layer to be true. The *jail* claims in the first paragraph do not, so
//// the run prints the helper's own enforcement report for the hermetic
//// build and for the satellite node, exactly as `e2e_test` does, and a
//// reader takes those lines rather than this doc as the ground truth for
//// what was confined. `make selftest` reports the same facts for the
//// layers no code-mode run exercises directly.
////
//// Feature-detected exactly like `e2e_test`: without the Go toolchain, the
//// Gleam/Erlang toolchains, or a prepared seed it prints a skip reason and
//// passes, so `make check` stays hermetic. `make e2e-codemode` builds both
//// first, so there it really runs.

import broker/budget
import broker/exec
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
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import simplifile
import support/rig.{type Prerequisites, type Rig}
import support/sample_repo

/// The sample, relative to the `codemode` package directory the test
/// runner starts in.
const sample_path = "../../docs/examples/stale_symbol_sweep.gleam"

/// The one line the whole execution reduces to. Fixed against
/// `support/sample_repo`'s fixture: `packages/core` holds the symbol in
/// two files, `packages/broker` in one, `packages/runtime` in none, and
/// `tools/build-quick` is the strategy that wins the race.
const expected_outcome = "packages/core=2 packages/broker=1 packages/runtime=0 build=quick exit=0"

/// The order the sweeps must *finish* in: the reverse of the order the
/// program lists them in, and of the order it reports them in.
const expected_completion_order = [
  "packages/runtime", "packages/broker", "packages/core",
]

pub fn code_mode_migration_sample_test() {
  case rig.prerequisites() {
    Error(reason) -> io.println("SKIP code_mode_migration_sample: " <> reason)
    Ok(prerequisites) -> run_sample(prerequisites)
  }
}

fn run_sample(prerequisites: Prerequisites) -> Nil {
  // Seven helpers: the satellite node holds one for the whole execution,
  // and at the hand-over between the race and the fan-out as many as five
  // more can be in flight at once.
  let live = rig.start(name: "migration-sample", prerequisites:, pool_size: 7)
  sample_repo.create(live.workspace)

  let source = read_sample()
  let execution = codemode.execute(source, exec_config(live, prerequisites))

  let assert codemode.Ran(source: returned, artifact:, outcome:) =
    execution.outcome
    as "the migration sample must vet, compile, and run to an outcome"
  // The source handed back for the durable entry is the file's own bytes.
  assert returned == source
  assert artifact.entry_module == compile.entry_module
  assert string.starts_with(artifact.manifest_hash, "sha256-")

  // One line, structured, off the terminal frame — not scraped stdout.
  let assert satellite.Completed(msgpack.StringValue(text)) = outcome
    as "the sample must complete with a text outcome"
  assert text == expected_outcome

  let overlap_ms = assert_fan_out_overlapped(live)
  assert_order_was_preserved(live)
  let ticks = assert_the_race_loser_was_killed(live)
  // Both jailed stages of a healthy run report what confined them; see
  // `e2e_test` for the assertion this shares.
  let assert enforcement.Reported(..) = execution.enforcement.build
    as "the hermetic build must report what its jail enforced"
  let assert enforcement.Reported(..) = execution.enforcement.node
    as "the satellite node must report what its jail enforced"
  announce(overlap_ms, ticks, execution.enforcement)

  rig.stop(live)
}

// --- the three non-vacuity checks ----------------------------------------

// All three sweeps were in flight at the same moment: the last one to
// start did so before the first one finished. Sequential execution
// cannot produce that, and neither can a `max_concurrency` the runtime
// quietly clamped to one.
fn assert_fan_out_overlapped(live: Rig) -> Int {
  let starts = sample_repo.stamps(live.workspace, sample_repo.starts_file)
  let completions =
    sample_repo.stamps(live.workspace, sample_repo.completions_file)
  assert list.length(starts) == 3
  assert list.length(completions) == 3
  let assert Ok(last_start) = list.reduce(list.map(starts, nanos), int.max)
    as "every sweep must have recorded a start"
  let assert Ok(first_completion) =
    list.reduce(list.map(completions, nanos), int.min)
    as "every sweep must have recorded a completion"
  assert last_start < first_completion
  { first_completion - last_start } / 1_000_000
}

// The sweeps finished in the reverse of the order the program lists them,
// and the outcome reported them in the program's order anyway. Without
// this the outcome assertion above would hold just as well for a
// `parallel_map` that returned results in completion order.
fn assert_order_was_preserved(live: Rig) -> Nil {
  let completions =
    sample_repo.stamps(live.workspace, sample_repo.completions_file)
  assert list.map(completions, fn(stamp) { stamp.dir })
    == expected_completion_order
  assert list.reverse(expected_completion_order) == sample_repo.swept
}

// The losing build strategy was killed where it stood. It ticks every
// half second for up to thirty; the race is decided about a third of a
// second in and the program then sweeps for three more seconds, so a
// loser left running would be at seven ticks or more by the end. At least
// one tick is required as well: a loser that never ran would satisfy any
// upper bound and prove nothing about cancellation.
fn assert_the_race_loser_was_killed(live: Rig) -> Int {
  let ticks = sample_repo.ticks(live.workspace)
  assert ticks >= 1
  assert ticks <= 4
  ticks
}

// Prints the evidence rather than only the verdict, so a passing run says
// how much margin it actually had — the same habit as `e2e_test`'s
// enforcement report.
fn announce(
  overlap_ms: Int,
  ticks: Int,
  reports: enforcement.Enforcement,
) -> Nil {
  io.println(
    "code-mode migration sample: three sweeps overlapped by "
    <> int.to_string(overlap_ms)
    <> "ms; the race loser stopped after "
    <> int.to_string(ticks)
    <> " tick(s) — a loser left running until the program ended reaches 7+",
  )
  // What the kernel under this run actually applied. The concurrency
  // claims above hold whatever it says; the *jail* claims in this
  // module's own doc hold only as far as these two lines go.
  io.println(
    "code-mode migration sample: "
    <> rig.enforcement_line("the hermetic build", reports.build),
  )
  io.println(
    "code-mode migration sample: "
    <> rig.enforcement_line("the satellite node", reports.node),
  )
}

fn nanos(stamp: sample_repo.Stamp) -> Int {
  stamp.nanos
}

fn read_sample() -> String {
  let assert Ok(source) = simplifile.read(sample_path)
    as "docs/examples/stale_symbol_sweep.gleam must be readable"
  source
}

// --- wiring ---------------------------------------------------------------

fn exec_config(live: Rig, prerequisites: Prerequisites) -> codemode.ExecConfig {
  let #(now, _clock) = clock.read(rig.wall_clock())
  let deadline = now + 180_000
  let path = rig.toolchain_path(prerequisites)
  // Eight outstanding effects: the node itself holds one, the race holds
  // two, and the fan-out three, with room for a cancelled loser that has
  // not yet settled when the fan-out starts.
  let pooled = budget.Budget(max_outstanding: 8, deadline_ms: deadline)
  let op = op_id(now)
  codemode.ExecConfig(
    vet_policy: vet_policy.default(),
    compile: compile.CompileConfig(
      build_root: live.build_root,
      dependencies: compile.default_dependencies(),
      generated: [],
      build: build.builder(build.BuildConfig(
        broker: live.broker,
        seed_root: prerequisites.seed_root,
        gleam_path: prerequisites.gleam_path,
        base_policy: live.base_policy,
        toolchain_roots: ["/"],
        demand: exec.BestEffort,
        env: [#("PATH", path)],
        dependencies: compile.default_dependencies(),
        timeout_ms: 120_000,
      )),
    ),
    broker: live.broker,
    // The build is accounted separately, under the derived
    // `migration-sample-build` sub-step; the node and every capability
    // call the program makes share the execution's own ledger.
    identity: identity.for_execution(
      op_id: op,
      step_id: "migration-sample",
      budget: pooled,
    )
      |> identity.with_own_build_ledger,
    satellite: satellite.SatelliteConfig(
      base_policy: live.base_policy,
      demand: exec.BestEffort,
      env: [#("PATH", path)],
      cwd: live.workspace,
      cap_socket_path: live.cap_socket_path,
      entropy: token.production_entropy(),
      clock: rig.wall_clock(),
      write_token_file: satellite.private_token_writer(live.token_dir),
      unlink_token_file: satellite.unlink_token_file,
      router: satellite.default_router,
      ceilings: [],
      call_timeout_ms: 60_000,
    ),
    launch: launch.launcher(launch.LaunchConfig(
      broker: live.broker,
      clock: rig.wall_clock(),
      erl_path: prerequisites.erl_path,
      demand: exec.BestEffort,
      accept_timeout_ms: 30_000,
    )),
  )
}

fn op_id(now: Int) -> ids.OpId {
  let generator = ids.generator(rig.wall_clock(), seed: now)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

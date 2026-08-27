//// The code-mode end-to-end acceptance: a real model-written program goes
//// through vetting, a real hermetic `gleam build` inside a network-off
//// jail, and a real jailed `erl` satellite that makes a real capability
//// call back through the broker over a real AF_UNIX socket — and the
//// structured `Outcome` that comes back carries what the jailed command
//// actually printed.
////
//// Feature-detected. When the Go toolchain, the Gleam/Erlang toolchain, or
//// the prepared build seed is missing, each test prints a skip reason and
//// passes, so `make check` stays hermetic and fast. `make e2e-codemode`
//// builds the helper and the seed first, so there it really runs.
////
//// # Degraded-mode honesty
////
//// The claims this suite can prove depend on what the kernel provides.
//// Every run prints the helper's own enforcement report for both the build
//// and the satellite, and says in as many words whether network-off was
//// *enforced* — the hermeticity claim rests entirely on that, and a run on
//// a kernel without seccomp proves the build works offline, not that it
//// could not have reached the network. `make selftest` reports the same
//// facts for the layers this suite does not exercise directly.

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
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/msgpack
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/string
import simplifile
import support/rig.{type Prerequisites, type Rig}

// What the jailed `/bin/echo` prints, and therefore what the program's
// structured outcome must carry back through three trust boundaries.
const echoed = "loom-code-mode"

const expected_outcome = "echo=loom-code-mode exit=0"

/// A program that vets, compiles, and makes one genuine capability call.
pub fn program_source() -> String {
  "import cap/proc\n"
  <> "import cap/report\n"
  <> "import gleam/int\n"
  <> "import gleam/string\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case proc.run(proc.command([\"/bin/echo\", \""
  <> echoed
  <> "\"])) {\n"
  <> "    Ok(output) ->\n"
  <> "      report.text(\n"
  <> "        \"echo=\"\n"
  <> "        <> string.trim(output.stdout)\n"
  <> "        <> \" exit=\"\n"
  <> "        <> int.to_string(output.exit_code),\n"
  <> "      )\n"
  <> "    Error(_error) -> report.failure(\"proc.run did not settle\")\n"
  <> "  }\n"
  <> "}\n"
}

// --- how long a jailed test is allowed to take ----------------------------

/// The ceiling on one test in this file.
///
/// Not a budget — a deadlock ceiling. Measured on this tree with a real
/// bubblewrap jail engaged, the four tests here cost 1.0 s, 1.0 s, 4.2 s
/// and 7.1 s, and 6 s of that last one is the deliberately short deadline
/// `a_runaway_program_dies_at_its_deadline` sets for itself rather than
/// work. The ceiling is deliberately *not* sized from those numbers,
/// because the case a ceiling exists for is not the normal one.
///
/// It is sized from what the code under test is *allowed* to consume
/// before something in Loom is obliged to speak. Per `rig.base_policy`
/// and the e2e's own config, one end-to-end run may legitimately spend
/// 120 s inside the hermetic build (`cpu_s`/`wall_s` are 120 s and 180 s;
/// `timeout_ms` is 120 s) plus a 10 s settle margin, then 30 s waiting
/// for the satellite to accept, then 60 s in a cap call: about 225 s of
/// sanctioned waiting before every layer has had its say.
///
/// That matters because when a jailed stage wedges, Loom is the thing
/// that should report it — "the hermetic build hit its wall limit and was
/// killed", or a `BuildRejected` carrying the compiler's own diagnostics
/// — since Loom knows what it was doing and eunit does not. A ceiling
/// below Loom's own limits takes that away and substitutes an anonymous
/// stack trace.
///
/// Which is exactly what happened. This suite spent its whole life under
/// eunit's *inherited* budget — gleeunit asks for `ScaleTimeouts(10)` over
/// eunit's 5-second default, so 50 seconds nobody in this tree chose. When
/// a real jail exposed the /dev masking bug behind issue #37 (see
/// `jail.BwrapArgs`), the guillotine fell at 50 s and reported `Timeout`
/// at a line number. Re-run against the same bug with this ceiling in
/// place, the failure arrives at 121 s reading `compile_failed`,
/// `build_rejected`, and the compiler's own text — the RLIMIT_CPU ceiling
/// of 120 s killing the spinning BEAM, reported by the layer that set it.
/// That is the sentence that points at the bug. A number chosen from the
/// stopwatch would have re-created the useless one.
///
/// 300 s: above the ~225 s of waiting the stack may legitimately do,
/// above the 120 s at which the worst real wedge observed here reports
/// itself, ~42x the slowest healthy test, and comfortably inside the
/// 45-minute cap on the `jail-linux` job that runs this suite for real.
const jailed_test_timeout_seconds = 300

/// gleeunit runs eunit with `ScaleTimeouts(10)`, and that scale is applied
/// to *every* timeout — including one a generator asks for explicitly, not
/// only to eunit's 5-second default. So the number handed to eunit has to
/// be the number we want divided by ten, and a reader who takes
/// `Timeout(300, _)` at face value would be setting fifty minutes: past
/// the 45-minute cap on the job that runs this, which turns a wedged test
/// into a killed CI job instead of a reported failure. Stated here rather
/// than folded into the constant, because the arithmetic is the whole
/// trap. (It is also how eunit's unchosen default came out as the 50 s
/// that guillotined this suite: 5 x 10.)
const gleeunit_timeout_scale = 10

/// The eunit test representation, built in Gleam rather than through FFI.
/// A Gleam constructor with fields compiles to a tagged Erlang tuple, so
/// `Timeout(300, body)` is literally `{timeout, 300, Body}` — which is
/// what eunit reads back from a zero-arity `*_test_` *generator* function.
/// (`*_test` without the trailing underscore is a plain test and takes
/// eunit's default; the underscore is what makes the timeout reachable at
/// all from a gleeunit suite.)
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

fn jailed(body: fn() -> Nil) -> EunitTest {
  Timeout(jailed_test_timeout_seconds / gleeunit_timeout_scale, body)
}

// --- the four scenarios ---------------------------------------------------

pub fn code_mode_end_to_end_test_() -> EunitTest {
  jailed(fn() {
    case rig.prerequisites() {
      Error(reason) -> io.println("SKIP code_mode_end_to_end: " <> reason)
      Ok(prerequisites) -> run_end_to_end(prerequisites)
    }
  })
}

pub fn hermetic_build_refuses_a_transitive_import_test_() -> EunitTest {
  jailed(fn() {
    case rig.prerequisites() {
      Error(reason) ->
        io.println(
          "SKIP hermetic_build_refuses_a_transitive_import: " <> reason,
        )
      Ok(prerequisites) -> run_transitive_import(prerequisites)
    }
  })
}

pub fn a_runaway_program_dies_at_its_deadline_test_() -> EunitTest {
  jailed(fn() {
    case rig.prerequisites() {
      Error(reason) ->
        io.println("SKIP a_runaway_program_dies_at_its_deadline: " <> reason)
      Ok(prerequisites) -> run_deadline(prerequisites)
    }
  })
}

pub fn a_type_error_comes_back_in_band_test_() -> EunitTest {
  jailed(fn() {
    case rig.prerequisites() {
      Error(reason) ->
        io.println("SKIP a_type_error_comes_back_in_band: " <> reason)
      Ok(prerequisites) -> run_type_error(prerequisites)
    }
  })
}

// --- the happy path -------------------------------------------------------

fn run_end_to_end(prerequisites: Prerequisites) -> Nil {
  let live = rig.start(name: "happy", prerequisites:, pool_size: 3)
  let execution =
    codemode.execute(program_source(), exec_config(live, prerequisites, "e2e"))

  let assert codemode.Ran(source:, artifact:, outcome:) = execution.outcome
    as "the program must vet, compile, and run to an outcome"
  // The source handed back for the durable entry is the source submitted.
  assert source == program_source()
  // A real artifact: the generated entry really was compiled, and the
  // manifest hash is a content address over the whole compiled set.
  assert artifact.entry_module == compile.entry_module
  assert string.starts_with(artifact.manifest_hash, "sha256-")
  assert simplifile.is_file(
      artifact.beam_dir <> "/" <> compile.entry_module <> ".beam",
    )
    == Ok(True)
  // The structured outcome carries what the jailed `/bin/echo` printed —
  // through the cap channel, the broker's policy check, a second jail, and
  // back. Nothing here is scraped from stdout.
  let assert satellite.Completed(msgpack.StringValue(text)) = outcome
    as "the program must complete with a text outcome"
  assert text == expected_outcome

  // Act two: the same build root again, with a stale artifact planted in
  // it. A build root is meant to be fresh, and this one is not — the
  // builder must clear what a previous run left rather than let it join
  // the artifact and its content address.
  let stale = artifact.beam_dir <> "/stale.beam"
  let assert Ok(Nil) = simplifile.write(to: stale, contents: "not a beam")
  let repeat =
    codemode.execute(
      program_source(),
      exec_config(live, prerequisites, "e2e-again"),
    )
  let assert codemode.Ran(artifact: again, outcome: repeated, ..) =
    repeat.outcome
    as "the pipeline must be repeatable over the same build root"
  assert repeated == outcome
  assert !rig.exists(stale)
  assert again.manifest_hash == artifact.manifest_hash

  // The acceptance issue #5 asks for: a *healthy* run — this one, the one
  // everybody actually runs — carries the enforcement report for both
  // jailed stages, not just the build's. The node's used to arrive (when
  // it arrived at all) after the outcome had already been reported, so a
  // green run could not prove the jail engaged at all.
  //
  // What is asserted is that each stage reported; *what* it reported is
  // printed, not asserted, because that is a property of the kernel this
  // runs on rather than of the harness.
  assert_both_stages_reported(execution.enforcement)
  assert_both_stages_reported(repeat.enforcement)
  announce(execution.enforcement)
  rig.stop(live)
}

// Both jailed stages of an execution said what the kernel applied to them.
// A stage that made no report fails here naming itself, rather than being
// quietly absent from a list.
fn assert_both_stages_reported(reports: enforcement.Enforcement) -> Nil {
  let assert enforcement.Reported(..) = reports.build
    as "the hermetic build must report what its jail enforced"
  let assert enforcement.Reported(..) = reports.node
    as "the satellite node must report what its jail enforced"
  Nil
}

// --- the build-graph gate -------------------------------------------------

fn run_transitive_import(prerequisites: Prerequisites) -> Nil {
  let live = rig.start(name: "transitive", prerequisites:, pool_size: 2)
  // Vetting is deliberately told to allow `core/msgpack`, so this program
  // reaches the compiler. `core` is a dependency of the *prelude*, not of
  // the generated program, and the hermetic build compiles with warnings
  // as errors — so the compiler refuses the import on its own, without
  // vetting's help (M4 triage CH-F1).
  let source =
    "import cap/report\n"
    <> "import core/msgpack\n"
    <> "\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  report.value(msgpack.NilValue)\n"
    <> "}\n"
  let execution =
    codemode.execute(
      source,
      codemode.ExecConfig(
        ..exec_config(live, prerequisites, "transitive"),
        vet_policy: vet_policy.new(["cap/report", "core/msgpack"]),
      ),
    )
  let assert codemode.CompileFailed(compile.BuildRejected(diagnostics:)) =
    execution.outcome
    as "importing a transitive dependency must fail the build, not run"
  assert string.contains(diagnostics, "direct dependency")
  assert string.contains(diagnostics, "core")
  // The build really ran — inside a jail — so it reports; the node never
  // existed, and says that rather than nothing at all.
  let assert enforcement.Reported(..) = execution.enforcement.build
    as "a build that rejected a program still reports what confined it"
  let assert enforcement.Unreported(reason) = execution.enforcement.node
  assert string.contains(reason, "did not compile")
  rig.stop(live)
}

// --- the deadline over a real node ----------------------------------------

fn run_deadline(prerequisites: Prerequisites) -> Nil {
  let live = rig.start(name: "deadline", prerequisites:, pool_size: 2)
  // A program that never returns and never makes a capability call. The
  // only thing that can end it is the wall deadline killing the node as a
  // unit — the host's timer plus `broker.abort` plus the jail's own wall
  // limit.
  let source =
    "import cap/report\n"
    <> "\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  spin(0)\n"
    <> "}\n"
    <> "\n"
    <> "fn spin(n: Int) -> report.Outcome {\n"
    <> "  case n < 0 {\n"
    <> "    True -> report.text(\"unreachable\")\n"
    <> "    False -> spin(n + 1)\n"
    <> "  }\n"
    <> "}\n"
  let config = exec_config(live, prerequisites, "deadline")
  // Compile under the generous budget the rig hands out, then run under a
  // deliberately short one, so the test spends its seconds on the deadline
  // rather than on the build.
  let assert vet.Passed(vetted) = vet.vet(source, config.vet_policy)
    as "the spinning program must vet"
  let assert Ok(artifact) =
    compile.compile(
      vetted,
      config.compile,
      identity.build_phase(config.identity),
    ).result
    as "the spinning program must compile"
  let #(started, _clock) = clock.read(rig.wall_clock())
  let short = budget.Budget(max_outstanding: 4, deadline_ms: started + 6000)
  let ran =
    satellite.run(
      artifact,
      identity.run_phase(identity.under_budget(config.identity, budget: short)),
      live.broker,
      config.satellite,
      config.launch,
    )
  let #(ended, _clock) = clock.read(rig.wall_clock())
  assert ran.outcome == Error(satellite.DeadlineExceeded)
  // The abort path answers too. This is the case the old side-channel lost
  // most reliably — the host aborts the operation and reports at once —
  // and it is the case where knowing whether the jail held matters most:
  // the program was still running when it was killed.
  //
  // Which of the two answers comes back is the kernel's to decide, and
  // the assertion is careful about the difference. A helper that survived
  // to write `exec_exit` reports its layers. One killed outright by the
  // cancel ladder never wrote one, and says *that* — which is a stage
  // that genuinely made no report, not one whose report lost a race with
  // the teardown. The reason must therefore name the execution's own end,
  // never this harness giving up waiting.
  case ran.node {
    enforcement.Reported(..) -> Nil
    enforcement.Unreported(reason:) -> {
      assert !string.contains(reason, "of teardown")
        as "a lost report must never be dressed up as a stage that had none"
      assert string.contains(reason, "did not settle with an exec_exit")
    }
  }
  io.println(
    "code-mode e2e: " <> rig.enforcement_line("the killed node", ran.node),
  )
  // Not vacuous: the node was alive right up to the deadline. Anything
  // that stopped it earlier — a node that would not boot, a satellite
  // that could not reach the socket — closes the cap channel and settles
  // as `SatelliteGone` within a second, not as a deadline six seconds in.
  assert ended - started >= 5000
  // Teardown really ran: the cap socket and the private token file are
  // gone, so nothing of this execution outlives it on disk. The host
  // reports its result before it finishes cleaning up, so give the
  // teardown a moment rather than racing it.
  assert gone_eventually(live.cap_socket_path)
  assert gone_eventually(live.token_dir <> "/cap-token")
  rig.stop(live)
}

fn gone_eventually(path: String) -> Bool {
  gone_loop(path, 40)
}

fn gone_loop(path: String, attempts: Int) -> Bool {
  case !rig.exists(path) {
    True -> True
    False ->
      case attempts <= 0 {
        True -> False
        False -> {
          process.sleep(50)
          gone_loop(path, attempts - 1)
        }
      }
  }
}

// --- the type checker as argument validator -------------------------------

fn run_type_error(prerequisites: Prerequisites) -> Nil {
  let live = rig.start(name: "type-error", prerequisites:, pool_size: 2)
  // A mistyped capability call is caught here, cheaply, before any
  // satellite spins up — the type checker doing double duty as the
  // tool-argument validator.
  let source =
    "import cap/proc\n"
    <> "import cap/report\n"
    <> "\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  let _ = proc.run(proc.command(\"not-an-argv\"))\n"
    <> "  report.text(\"unreachable\")\n"
    <> "}\n"
  let execution =
    codemode.execute(source, exec_config(live, prerequisites, "type-error"))
  let assert codemode.CompileFailed(compile.BuildRejected(diagnostics:)) =
    execution.outcome
    as "a type error must come back in band"
  assert string.contains(diagnostics, "Type mismatch")
  rig.stop(live)
}

// --- wiring ---------------------------------------------------------------

fn exec_config(
  live: Rig,
  prerequisites: Prerequisites,
  step_id: String,
) -> codemode.ExecConfig {
  let #(now, _clock) = clock.read(rig.wall_clock())
  let deadline = now + 180_000
  let path = rig.toolchain_path(prerequisites)
  let pooled = budget.Budget(max_outstanding: 4, deadline_ms: deadline)
  codemode.ExecConfig(
    vet_policy: vet_policy.default(),
    compile: compile.CompileConfig(
      build_root: live.build_root,
      dependencies: compile.default_dependencies(),
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
    // One identity for the whole execution, with the hermetic build
    // accounted separately: a different jail under a different policy,
    // finished before the node starts, so the two pooled caps are never
    // live at once. `-build` is the derived sub-step, not a second
    // identity the caller wrote.
    identity: identity.for_execution(
      op_id: op_id(now),
      step_id:,
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

// Prints what the running kernel actually enforced, and says plainly when
// the hermeticity claim was not proven here rather than letting a green
// test imply it was.
fn announce(reports: enforcement.Enforcement) -> Nil {
  io.println(
    "code-mode e2e: "
    <> rig.enforcement_line("the hermetic build", reports.build),
  )
  io.println(
    "code-mode e2e: "
    <> rig.enforcement_line("the satellite node", reports.node),
  )
  let network_off =
    list.any([reports.build, reports.node], fn(report) {
      let #(applied, _skipped) = enforcement.layers(report)
      list.contains(applied, "seccomp-net")
    })
  case network_off {
    True ->
      io.println(
        "code-mode e2e: network-off ENFORCED — the hermetic build could not "
        <> "have reached the network",
      )
    False ->
      io.println(
        "code-mode e2e: network-off NOT ENFORCED on this kernel — the build "
        <> "ran offline, but this run does NOT prove it could not reach the "
        <> "network; see `make selftest`",
      )
  }
}

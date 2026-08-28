//// The code-mode **orchestration sample** — M4.5's named acceptance
//// criterion.
////
//// `docs/examples/fan_out_review.gleam` is the readable artifact: a
//// program of the kind a model writes instead of three `agent_spawn`
//// calls and an `agent_wait`. This suite reads *that file, verbatim* and
//// puts it through the real pipeline — real vetting against the real
//// orchestration allowlist, a real hermetic `gleam build` in a
//// network-off jail, a real `erl` satellite, a real AF_UNIX cap channel,
//// and the real `codemode/orchestration` router — against the same
//// fixture repository the migration sample sweeps, and asserts on the
//// structured outcome that comes back.
////
//// Reading the file rather than restating it inline is deliberate, and it
//// is the same arrangement `migration_sample_test` has: the documented
//// artifact and the executed one cannot drift, and a sample edited into
//// something that no longer vets, compiles, or runs fails here.
////
//// # What is scripted, and what that costs the claim
////
//// The Agency is scripted (`support/fake_agency`). `codemode` cannot see
//// a live runtime — that lives in `client` — so the children are played
//// by a fake that reads the *real* fixture off disk and answers with what
//// it found. Everything between the program and that fake is real: the
//// vetting, the compile, the jail, the wire, the router, the caller
//// derivation, the result-contract carriage, the value bridge.
////
//// What is therefore *not* claimed here is the authorization model. That
//// is `client/agency`'s, and it is proved twice over on that side —
//// against a live runtime in `agency_test`, and through this very router
//// in `client/test/client/codemode_test.gleam`, where a real Agency
//// refuses a spawn and a send outside the program's own lineage.
////
//// # The non-vacuity checks
////
//// The outcome line alone would pass whether or not the interesting
//// properties held, so three assertions read the evidence back:
////
//// - **The fan-out is really three children.** Three spawns reach the
////   Agency, with three *distinct* minted names — the property the call's
////   ordinal exists for, and the one a program looping over one purpose
////   would break silently.
//// - **The join is really one call over one deadline.** One `wait`
////   carrying all three handles, not three waits carrying one each.
//// - **The result is really structured.** The counts come back as
////   integers the program added up, and `by_package` is in the order the
////   program listed the packages rather than the order the answers were
////   built — which is what makes the zip in the sample a claim rather
////   than a coincidence.
////
//// Feature-detected exactly like `migration_sample_test`: without the Go
//// toolchain, the Gleam/Erlang toolchains, or a prepared seed it prints a
//// skip reason and passes, so `make check` stays hermetic. `make
//// e2e-codemode` builds both first, so there it really runs.

import broker/budget
import broker/exec
import broker/token
import codemode/build
import codemode/codemode
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/launch
import codemode/orchestration
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/json
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import simplifile
import support/fake_agency.{type Seen}
import support/rig.{type Prerequisites, type Rig}
import support/sample_repo
import tools/agent

/// The sample, relative to the `codemode` package directory the test
/// runner starts in.
const sample_path = "../../docs/examples/fan_out_review.gleam"

/// The step the execution runs under, in the shape the planner mints one
/// — a canonical thirty-six character UUIDv7 rather than a short literal,
/// because the name derivation the children's call site feeds has to
/// survive the production length and a short fixture cannot ask it to.
fn step() -> String {
  let #(entry, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 7))
  ids.entry_id_to_string(entry)
}

/// What the fixture holds: `packages/core` mentions the symbol in two
/// files, `packages/broker` in one, `packages/runtime` in none. The
/// counts are distinct so an answer delivered against the wrong package
/// is visible rather than lucky.
const expected_counts = [
  #("packages/core", 2),
  #("packages/broker", 1),
  #("packages/runtime", 0),
]

/// The join window the sample asks for, and therefore the one deadline
/// the Agency must be handed. Kept byte-identical to `join_ms` in
/// `docs/examples/fan_out_review.gleam`.
const expected_join_ms = 20_000

pub fn code_mode_orchestration_sample_test() {
  case rig.prerequisites() {
    Error(reason) ->
      io.println("SKIP code_mode_orchestration_sample: " <> reason)
    Ok(prerequisites) -> run_sample(prerequisites)
  }
}

fn run_sample(prerequisites: Prerequisites) -> Nil {
  // Two helpers: the satellite node holds one for the whole execution and
  // the hermetic build holds one before it. An orchestration program runs
  // no jailed process of its own — it has no `cap/proc` to run one with.
  let live =
    rig.start(name: "orchestration-sample", prerequisites:, pool_size: 2)
  sample_repo.create(live.workspace)

  let seen = process.new_subject()
  let source = read_sample()
  let execution =
    codemode.execute(source, exec_config(live, prerequisites, seen))

  let assert codemode.Ran(source: returned, artifact:, outcome:) =
    execution.outcome
    as "the orchestration sample must vet, compile, and run to an outcome"
  assert returned == source
  assert artifact.entry_module == compile.entry_module
  assert string.starts_with(artifact.manifest_hash, "sha256-")

  let assert satellite.Completed(value) = outcome
    as "the sample must complete with a structured outcome"
  assert_the_reduction_is_right(value)
  // Drained once and shared: a second drain would answer with an empty
  // list and every assertion over it would hold vacuously.
  let recorded = fake_agency.drain(seen)
  assert_the_fan_out_was_three_distinct_children(recorded)
  assert_the_join_was_one_call_on_one_deadline(recorded)

  // Every code-mode outcome carries the satellite's enforcement report,
  // the happy path included (issue #5).
  let assert enforcement.Reported(..) = execution.enforcement.build
    as "the hermetic build must report what its jail enforced"
  let assert enforcement.Reported(..) = execution.enforcement.node
    as "the satellite node must report what its jail enforced"
  announce(execution.enforcement)

  rig.stop(live)
}

// --- what came back --------------------------------------------------------

// One structured result, off the terminal frame — not scraped stdout and
// not prose the harness would have to parse.
fn assert_the_reduction_is_right(value: MsgPackValue) -> Nil {
  assert field(value, "symbol") == msgpack.StringValue(sample_repo.symbol)
  assert field(value, "packages_asked") == msgpack.IntValue(3)
  assert field(value, "packages_reviewed") == msgpack.IntValue(3)
  // The sum the program computed, over integers it read out of typed
  // results rather than out of sentences.
  assert field(value, "hits") == msgpack.IntValue(3)
  assert field(value, "unfinished") == msgpack.ArrayValue([])
  // In the order the program listed the packages. A join that answered in
  // completion order — or a zip that lost the pairing — would show up
  // here as a reordering or as counts against the wrong package, which
  // the fixture's distinct counts make visible.
  let assert msgpack.MapValue(entries:) = field(value, "by_package")
    as "by_package must be an object"
  assert list.map(entries, fn(entry) { entry })
    == list.map(expected_counts, fn(one) {
      #(msgpack.StringValue(one.0), msgpack.IntValue(one.1))
    })
}

// --- what the messaging plane saw -----------------------------------------

fn assert_the_fan_out_was_three_distinct_children(recorded: List(Seen)) -> Nil {
  let spawns = list.filter_map(recorded, spawn_only)
  assert list.length(spawns) == 3
  // Every spawn stated the shape it wanted back, which is what makes the
  // counts above integers rather than prose.
  assert list.all(spawns, fn(one) { one.1.result_schema != option.None })
  // Three distinct children, from three distinct call ordinals. Two
  // spawns sharing an ordinal would mint one name twice and the second
  // would reconcile onto the first child.
  //
  // The names have to differ on the ordinal alone: every other coordinate
  // is the same for all three, and the ordinal is the only one this
  // program can move. Varying it is the axis that always worked, which is
  // why this check on its own never saw the collisions — the ones that
  // matter are in `orchestration_test`, over the axes that were fixed.
  let names =
    list.map(spawns, fn(one) { fake_agency.minted(one.0, one.1).strand })
  assert list.length(list.unique(names)) == 3
  // The dispatching call's index is one execution's, so it is the same
  // for all three; the ordinal is what counts the spawns.
  assert list.all(spawns, fn(one) { one.0.source_index == 0 })
  // And every one of them was judged as the strand that dispatched the
  // `code_mode` call, under the operation the pipeline threaded.
  assert list.all(spawns, fn(one) { one.0.strand == "main" })
  // The step is the threaded identity's, carried through untouched, and
  // what marks these as a program's children is the minter beside it.
  assert list.all(spawns, fn(one) { one.0.step_id == step() })
  assert list.map(spawns, fn(one) { one.0.minter })
    == [
      agent.Program(ordinal: 0),
      agent.Program(ordinal: 1),
      agent.Program(ordinal: 2),
    ]
}

fn assert_the_join_was_one_call_on_one_deadline(recorded: List(Seen)) -> Nil {
  let joins =
    list.filter_map(recorded, fn(one) {
      case one {
        fake_agency.SawWait(caller: _, handles:, within_ms:) ->
          Ok(#(handles, within_ms))
        _other -> Error(Nil)
      }
    })
  let assert [#(handles, within_ms)] = joins
    as "the sample must join once, not once per child"
  assert list.length(handles) == 3
  assert within_ms == expected_join_ms
}

fn spawn_only(one: Seen) -> Result(#(agent.Caller, agent.SpawnRequest), Nil) {
  case one {
    fake_agency.SawSpawn(caller:, request:) -> Ok(#(caller, request))
    _other -> Error(Nil)
  }
}

// --- the scripted children -------------------------------------------------

// An Agency whose children read the real fixture. Each answers with the
// count of files under its package that mention the symbol, in the shape
// its spawn demanded — so the numbers the program adds up are the
// fixture's, not the test's.
fn reviewing_agency(workspace: String, seen: Subject(Seen)) -> agent.Agency {
  fake_agency.admitting(seen, fn(handle) {
    fake_agency.completed_with(handle, reviewed(workspace, handle))
  })
}

fn reviewed(workspace: String, handle: agent.Handle) -> agent.TerminalResult {
  case package_of(handle) {
    Error(Nil) -> agent.ResultAbsent(schema: unreachable_schema())
    Ok(package) ->
      agent.ResultGiven(
        value: json.Object([
          #("package", json.String(package)),
          #("hits", json.Int(hits_in(workspace, package))),
        ]),
      )
  }
}

// Which package a child was spawned for, read off the name the Agency
// minted from its purpose. Matching on the minted name rather than on a
// side table is deliberate: it is evidence that the purpose really did
// reach the name.
fn package_of(handle: agent.Handle) -> Result(String, Nil) {
  list.find(sample_repo.swept, fn(package) {
    case agent.slug("review " <> package) {
      Ok(slug) -> string.contains(handle.strand, slug)
      Error(Nil) -> False
    }
  })
}

// How many files under `package` mention the symbol. The fixture is
// flat one level deep, which is all this needs to be.
fn hits_in(workspace: String, package: String) -> Int {
  let directory = workspace <> "/" <> package
  case simplifile.read_directory(directory) {
    Error(_error) -> 0
    Ok(names) ->
      list.count(names, fn(name) {
        case simplifile.read(directory <> "/" <> name) {
          Error(_error) -> False
          Ok(contents) -> string.contains(contents, sample_repo.symbol)
        }
      })
  }
}

fn unreachable_schema() -> agent.ResultSchema {
  let assert Ok(schema) =
    agent.parse_result_schema(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #("hits", json.Object([#("type", json.String("integer"))])),
          ]),
        ),
        #("required", json.Array([json.String("hits")])),
      ]),
    )
    as "the fixture schema must parse"
  schema
}

// --- reading the artifact --------------------------------------------------

fn read_sample() -> String {
  let assert Ok(source) = simplifile.read(sample_path)
    as "docs/examples/fan_out_review.gleam must be readable"
  source
}

fn field(value: MsgPackValue, key: String) -> MsgPackValue {
  let assert msgpack.MapValue(entries:) = value
    as "the outcome must be an object"
  let assert Ok(found) =
    list.find_map(entries, fn(entry) {
      case entry.0 == msgpack.StringValue(key) {
        True -> Ok(entry.1)
        False -> Error(Nil)
      }
    })
    as { "the outcome must carry " <> key }
  found
}

fn announce(reports: enforcement.Enforcement) -> Nil {
  io.println(
    "code-mode orchestration sample: three reviewers, one join, "
    <> int.to_string(3)
    <> " packages reduced to one structured result",
  )
  io.println(
    "code-mode orchestration sample: "
    <> rig.enforcement_line("the hermetic build", reports.build),
  )
  io.println(
    "code-mode orchestration sample: "
    <> rig.enforcement_line("the satellite node", reports.node),
  )
}

// --- wiring ---------------------------------------------------------------

fn exec_config(
  live: Rig,
  prerequisites: Prerequisites,
  seen: Subject(Seen),
) -> codemode.ExecConfig {
  let #(now, _clock) = clock.read(rig.wall_clock())
  let deadline = now + 180_000
  let path = rig.toolchain_path(prerequisites)
  // Four outstanding effects: the node holds one for its whole life and
  // the program's three spawns can be in flight together.
  let pooled = budget.Budget(max_outstanding: 4, deadline_ms: deadline)
  codemode.ExecConfig(
    // The orchestration allowlist, and nothing about the wiring makes it
    // optional: the sample imports `cap/strand`, which no other policy
    // admits.
    vet_policy: vet_policy.orchestration(),
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
    identity: identity.for_execution(
      op_id: op_id(now),
      step_id: step(),
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
      router: orchestration.router(orchestration.Orchestration(
        agency: reviewing_agency(live.workspace, seen),
        strand: "main",
        source_index: 0,
      )),
      ceilings: orchestration.ceilings(orchestration.default_spawn_ceiling),
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

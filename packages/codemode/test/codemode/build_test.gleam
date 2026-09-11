//// Production-builder tests that need no kernel: the policy the hermetic
//// build puts to the session base, and the refusals that happen before any
//// clearance is attempted. The build itself — a real `gleam build` in a
//// real network-off jail — is `codemode/e2e_test`.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import broker/token
import codemode/build
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/seed
import core/clock
import core/ids
import gleam/list
import gleam/string
import simplifile
import tools/tool

const t = 1_700_000_000_000

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 13)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/build-" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

// A broker with no helper behind it. Every test here refuses before a
// clearance is ever attempted, so it is never asked for one.
fn idle_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  started
}

// The build phase of one execution, derived — never assembled. The
// execution here accounts its build separately, so the derived step is
// `step-1-build`.
fn build_phase() -> identity.PhaseIdentity {
  identity.for_execution(
    op_id: op_id(),
    step_id: "step-1",
    budget: budget.Budget(max_outstanding: 2, deadline_ms: t + 120_000),
  )
  |> identity.with_own_build_ledger
  |> identity.build_phase
}

fn config(seed_root: String) -> build.BuildConfig {
  build.BuildConfig(
    observe: tool.ignore_output(),
    broker: idle_broker(),
    seed_root:,
    gleam_path: "/usr/local/bin/gleam",
    base_policy: policy.SandboxPolicy(
      ..policy.workspace_default("/work"),
      readable_roots: ["/"],
      network: policy.NetworkFull,
    ),
    toolchain_roots: ["/"],
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    dependencies: compile.default_dependencies(),
    timeout_ms: 60_000,
  )
}

pub fn the_build_requires_the_network_off_test() {
  let root = fresh_dir("requirements")
  let requirements = build.build_requirements(config("/seed"), root)
  assert requirements.network == policy.NetworkOff
  // Against a network-*full* base, the meet is still off: a hermetic build
  // cannot be widened by a permissive session.
  let #(effective, _narrowings) =
    policy.compose(
      base: policy.SandboxPolicy(
        ..policy.workspace_default("/work"),
        network: policy.NetworkFull,
      ),
      requirements:,
      grants: [],
    )
  assert effective.network == policy.NetworkOff
}

pub fn the_build_writes_only_to_its_own_root_test() {
  let root = fresh_dir("writable")
  let requirements = build.build_requirements(config("/seed"), root)
  assert requirements.writable_roots == [root]
  // The workspace the session may otherwise write is not writable here:
  // a build is a build, not a licence to edit the user's tree.
  assert !list.contains(requirements.writable_roots, "/work")
}

pub fn the_build_allows_only_the_environment_it_passes_test() {
  let requirements = build.build_requirements(config("/seed"), "/root")
  // PATH is not optional because `gleam build` shells out to `erl`, and
  // TMPDIR names the writable temporary directory inside the build root.
  assert requirements.env_allow == ["TMPDIR", "PATH"]
}

pub fn the_build_pins_its_temporary_directory_test() {
  let root = "/work/build"
  let configured =
    build.BuildConfig(..config("/seed"), env: [
      #("PATH", "/usr/bin"),
      #("TMPDIR", "/host/tmp"),
    ])
  let call = build.build_call(configured, build_phase(), root)
  assert list.key_find(call.env, "TMPDIR") == Ok(root <> "/tmp")
  // The pinned value is unique, so helper-side map construction cannot
  // choose a caller-supplied duplicate instead.
  assert list.count(call.env, fn(pair) { pair.0 == "TMPDIR" }) == 1
  assert call.requirements.env_allow == ["TMPDIR", "PATH"]
  // TMPDIR belongs only to the derived build call. The caller's session base
  // stays unchanged, while composition preserves the harness-owned name.
  assert !list.contains(configured.base_policy.env_allow, "TMPDIR")
  assert list.contains(call.base_policy.env_allow, "TMPDIR")
  let #(effective, narrowings) =
    policy.compose(
      base: call.base_policy,
      requirements: call.requirements,
      grants: [],
    )
  assert list.contains(effective.env_allow, "TMPDIR")
  assert narrowings == []
}

pub fn a_missing_seed_is_reported_before_any_clearance_test() {
  let root = fresh_dir("no-seed")
  let builder = build.builder(config("/nonexistent/codemode-seed"))
  let built = builder(build_phase(), root, [])
  let assert Error(compile.BuildUnavailable(reason:)) = built.result
  assert string.contains(reason, "make codemode-seed")
  // A build that was never dispatched claims nothing about a jail, and
  // says which of the two states it is in rather than staying silent.
  let assert enforcement.Unreported(why) = built.enforcement
  assert string.contains(why, "never dispatched")
  // Nothing was cloned into the root, because nothing was attempted.
  assert simplifile.is_directory(root <> "/vendor") != Ok(True)
}

pub fn a_seed_pinned_to_other_dependencies_is_refused_test() {
  let root = fresh_dir("mismatched-root")
  let seed_root = fresh_dir("mismatched-seed")
  let assert Ok(Nil) =
    seed.prepare(root: seed_root, vendored: [], dependencies: [
      compile.HexDependency(name: "gleam_stdlib", requirement: "1.0.4"),
      compile.PathDependency(name: "cap", path: compile.prelude_path),
    ])
  let builder = build.builder(config(seed_root))
  let built = builder(build_phase(), root, [])
  let assert Error(compile.BuildUnavailable(reason:)) = built.result
  assert string.contains(reason, "different dependency table")
  let assert enforcement.Unreported(_why) = built.enforcement
}

// --- the clone's copy order ------------------------------------------------

// The manifest hash was once unstable because cloning a seed copied its
// whole `build` tree in one go, leaving the relative age of the
// dependencies' sources and the artifacts derived from them to directory
// traversal order. Gleam re-copies and re-`erlc`s a dependency's native
// `.erl` whenever the source reads as newer than the copy under
// `build/dev`, and that is the one freshness question with no content
// hash behind it — so on a host whose traversal happened to reach `dev`
// first, 39 of the 78 compiled modules were rebuilt, each recording the
// build root's path in its own chunks and moving the address.
//
// The order is now decided here rather than by the filesystem, so this is
// the assertion that keeps it decided.
pub fn a_clone_copies_dependency_sources_first_test() {
  assert build.clone_order(["dev", "packages"]) == ["packages", "dev"]

  // Traversal order is what varied between hosts, so the answer must not
  // depend on the order the children arrive in.
  assert build.clone_order(["packages", "dev"]) == ["packages", "dev"]
}

// The lock files sitting beside `packages` and `dev` are children of the
// same directory, and a clone that dropped one would leave the build root
// missing something the seed had. Ordering the copy must not become
// filtering it.
pub fn a_clone_carries_every_child_of_the_seeds_build_test() {
  let entries = ["dev", "gleam-dev-erlang.lock", "packages", "gleam.lock"]
  let ordered = build.clone_order(entries)

  assert list.sort(ordered, string.compare)
    == list.sort(entries, string.compare)
  assert list.first(ordered) == Ok(build.package_sources)
}

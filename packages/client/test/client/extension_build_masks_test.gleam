//// The masks an extension install's hermetic build is handed, judged as
//// a value rather than by running bwrap.
////
//// The failure this file exists for was measured on a Linux host with a
//// real jail. The install's build plane took its base from the session
//// constructor, which protects the workspace's content-addressed blob
//// store, and the extensions root it was given holds no such store. So
//// the composed build clearance carried a mask over a directory that did
//// not exist, and `codemode/build.build_requirements` had already
//// narrowed the one writable root down to the build directory, leaving
//// the mask's parent read-only. bwrap cannot create a mask for a path it
//// can neither find nor make, and it said so: `protected path(s)
//// <root>/.blobs do not exist and the region covering their parent
//// directory is not writable`. The refusal is correct, and it took every
//// jailed compile with it, so the fix is to stop constructing the entry.
////
//// Both halves are asserted together, because either alone is a policy
//// somebody could ship by accident. A session must keep masking its blob
//// store — that mask is what stops a jailed `proc.run` pre-planting bytes
//// at a future content address — and the install's build must be handed
//// no mask its jail could not build. The same file therefore pins the
//// session posture that must not regress and the build posture that was
//// wrong.
////
//// The third posture arrived with issue #242. The extensions root is
//// `<state_root>/extensions` by default, so an install's build runs one
//// directory below the daemon's owner token, catalogue and session
//// databases — under `readable_roots: ["/"]`, on a jail whose base view
//// is the whole host. Those entries are masked when they exist and
//// filtered when they do not, which is the same buildability question
//// the blob store failed, answered the other way round.
////
//// Pure: no helper, no kernel, no bwrap. The real jailed run lives in
//// `client/extension_test`.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/serve
import codemode/build
import codemode/compile
import core/clock
import gleam/list
import gleam/string
import simplifile

const t = 1_700_000_000_000

pub fn the_build_plane_masks_no_blob_store_test() {
  let root = fresh_dir("plane")
  let state_root = root <> "-state"

  // An install root holds no blob store, so there is nothing under it a
  // mask would be protecting. Not constructing the entry is what makes
  // the unbuildable mask unrepresentable rather than merely filtered out
  // one composition step later.
  let masks = serve.build_plane_policy(root, state_root).protected
  assert !list.any(masks, string.ends_with(_, "/.blobs"))
    as "an install's build plane masks no blob store"

  // A state root no daemon has written is a set of paths that do not
  // exist under a parent the build may not write, which is the shape
  // bwrap refuses. The filter is what keeps an install on a fresh host
  // working at all.
  assert masks == [] as "an unwritten state root contributes no mask"

  // And the plane starts on it, which is the check `start_build_plane`
  // makes before it spawns anything.
  assert serve.base_policy_fault(serve.build_plane_policy(root, state_root))
    == Ok(Nil)
}

pub fn the_build_plane_masks_the_daemon_state_root_test() {
  let root = fresh_dir("state-plane")
  let state_root = fresh_dir("state-plane-state")

  // The four entries `client/daemon/root.directories` writes before it
  // admits anything. They exist on this host, so the jail can bind over
  // them whatever the build's writable root has been narrowed to, which
  // is why these are the ones the probe asserts on.
  let established = [
    state_root <> "/owner.token",
    state_root <> "/catalogue.db",
    state_root <> "/daemon.lock",
    state_root <> "/sessions",
  ]
  let assert Ok(Nil) = simplifile.create_directory(state_root <> "/sessions")
    as "the fixture sessions directory must be creatable"
  list.each(established, fn(path) {
    let _written = simplifile.write(path, "x")
  })

  // Without this the install's jailed build reads the owner token by
  // absolute path: the build plane grants `readable_roots: ["/"]` and
  // the jail's base view is the whole host, so a mask is the only thing
  // in the way.
  let masks = serve.build_plane_policy(root, state_root).protected
  list.each(established, fn(path) {
    assert list.contains(masks, path)
      as { "the build plane must mask " <> path }
  })
}

pub fn a_session_still_masks_its_blob_store_test() {
  let workspace = fresh_dir("session")

  // The posture the fix must not have cost. A session's blob store is
  // created before its first jail and lives under the session's own
  // writable root, so the mask is both buildable and load-bearing.
  assert list.any(serve.base_policy(workspace).protected, fn(entry) {
    string.ends_with(entry, "/.blobs")
  })
    as "a session still masks its blob store"
}

pub fn the_build_clearance_carries_no_unbuildable_mask_test() {
  let root = fresh_dir("requirements")
  let build_root = root <> "/.staging/build"
  let requirements = build_requirements(root, build_root)

  // The narrowing that turned an inherited mask into a refusal: after it,
  // the only writable root is the build directory, so any protected entry
  // outside it must already exist on disk or the jail cannot make one.
  assert requirements.writable_roots == [build_root]
    as "the hermetic build has exactly one writable root"

  list.each(requirements.protected, fn(entry) {
    assert exists(entry) || policy.covers(root: build_root, path: entry)
      as { "the jail could build a mask for " <> entry }
  })
}

// The clearance an extension install's build really puts to its plane:
// `codemode/build`'s own composition over the plane's base policy, so a
// change to either side is caught here rather than on a Linux host.
fn build_requirements(
  root: String,
  build_root: String,
) -> policy.SandboxPolicy {
  build.build_requirements(
    build.BuildConfig(
      broker: idle_broker(),
      seed_root: root <> "/seed",
      gleam_path: "/usr/local/bin/gleam",
      base_policy: serve.build_plane_policy(root, root <> "-state"),
      toolchain_roots: ["/"],
      demand: exec.BestEffort,
      env: [#("PATH", "/usr/bin")],
      dependencies: compile.default_dependencies(),
      timeout_ms: 60_000,
    ),
    build_root,
  )
}

// A broker with no helper behind it. Nothing here dispatches a call; the
// field exists because `BuildConfig` holds one, and a policy question is
// answered without ever asking for a clearance.
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

fn exists(path: String) -> Bool {
  case simplifile.is_file(path), simplifile.is_directory(path) {
    Ok(True), _ -> True
    _, Ok(True) -> True
    _, _ -> False
  }
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory must be readable"
  let path = here <> "/build/extension-build-masks-" <> name
  let _cleared = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "the fixture directory must be creatable"
  path
}

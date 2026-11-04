//// Apply against real repositories and the real sandbox helper
//// (protocol-change/107, "Apply"). A source repository with uncommitted work is
//// captured thin against a receiver that holds the base, stored by hash, and
//// applied into the receiver's repository; the tests then look at exactly what
//// changed there, and at what a hostile `.git/config`, a wrong hash, a short
//// file or a lying description is not allowed to change.

import client/repository_snapshot
import client/state_apply.{Clone, Worktree}
import client/state_object.{type State, Full, State, Thin}
import client/state_store
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/state_rig.{type Rig}
import support/worktree_rig

type Scenario {
  Scenario(
    rig: Rig,
    /// The receiver: a clone made after the second commit.
    receiver: String,
    /// The state of the source's dirty tree, thin against the second commit.
    state: State,
    /// Where the store holds its bundle.
    bundle: String,
    /// The source's second commit, which the receiver holds.
    base: String,
    /// The source's third commit, which it does not.
    third: String,
  )
}

fn now() -> Int {
  bootstrap.system_time_ms() / 1000
}

// A source with three commits and uncommitted work, and a receiver that holds
// the first two.
fn scenario(name: String) -> Scenario {
  let rig = state_rig.rig(name)
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let base = state_rig.commit_file(rig.root, "two", "two\n", "second")
  let receiver = state_rig.clone(rig, "receiver")
  let third = state_rig.commit_file(rig.root, "README", "three\n", "third")
  worktree_rig.write(rig.root <> "/README", "dirty\n")
  worktree_rig.write(rig.root <> "/notes/new.txt", "untracked\n")
  worktree_rig.write(rig.root <> "/notes/deep/more.txt", "deeper\n")
  let assert Ok(candidates) =
    repository_snapshot.base_candidates(rig.git, rig.call, 30_000)
  let basis = state_object.choose_basis(candidates, [base, c1])
  assert basis == Thin(base)
  let snapshot = state_rig.capture(rig, "thin", basis)
  let #(state, bundle) = stored(rig, snapshot)
  Scenario(rig:, receiver:, state:, bundle:, base:, third:)
}

// Admits a snapshot's bundle to the node's store and reads it back, which is
// the path a receiving node's apply takes.
fn stored(
  rig: Rig,
  snapshot: repository_snapshot.Snapshot,
) -> #(State, String) {
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(state) =
    state_store.put(
      store,
      snapshot.bundle,
      tip: snapshot.commit,
      base: snapshot.base,
      dirty: snapshot.dirty,
      now_s: now(),
    )
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  #(held.state, held.path)
}

fn destination(rig: Rig, session: Int) -> String {
  let parent = rig.state <> "/worktrees/receiver"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(parent)
  parent <> "/" <> worktree_rig.session(session)
}

fn placement(scenario: Scenario, session: Int) -> state_apply.Placement {
  Worktree(
    repository: scenario.receiver,
    destination: destination(scenario.rig, session),
    session: worktree_rig.session(session),
  )
}

fn index_of(repository: String) -> BitArray {
  let assert Ok(bytes) = simplifile.read_bits(repository <> "/.git/index")
  bytes
}

// A bundle file outside the masked state root, for the tests that doctor one.
fn doctored(rig: Rig, name: String, bytes: BitArray) -> String {
  let directory = rig.scratch <> "/doctored"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let path = directory <> "/" <> name
  let assert Ok(Nil) = simplifile.write_bits(path, bytes)
  path
}

fn state_for(bytes: BitArray, like: State) -> State {
  State(
    ..like,
    hash: state_object.hash_of(bytes),
    size: bit_array.byte_size(bytes),
  )
}

pub fn a_stored_thin_state_becomes_a_worktree_on_a_new_branch_test() {
  let scenario = scenario("apply")
  let rig = scenario.rig
  let before = state_rig.refs(scenario.receiver)
  let head_before = worktree_rig.git(scenario.receiver, ["rev-parse", "HEAD"])
  let index_before = index_of(scenario.receiver)
  let session = worktree_rig.session(1)
  let tree = destination(rig, 1)

  let assert Ok(applied) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      placement(scenario, 1),
    )
  assert applied.tip == scenario.state.tip
  assert applied.destination == tree
  assert applied.branch == "loom/" <> session
  assert applied.ref == state_object.incoming_ref(scenario.state.hash)

  // The uncommitted work arrives as the first commit on the branch, on top of
  // the source's last commit, untracked files included.
  assert simplifile.read(tree <> "/README") == Ok("dirty\n")
  assert simplifile.read(tree <> "/notes/new.txt") == Ok("untracked\n")
  assert simplifile.read(tree <> "/notes/deep/more.txt") == Ok("deeper\n")
  assert worktree_rig.git(tree, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/" <> session
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == scenario.state.tip
  assert worktree_rig.git(tree, ["log", "-1", "--format=%s"])
    == "Working snapshot"
  assert worktree_rig.git(tree, ["rev-parse", "HEAD^"]) == scenario.third
  assert worktree_rig.git(tree, ["status", "--porcelain"]) == ""
  assert string.contains(
    worktree_rig.git(scenario.receiver, ["worktree", "list", "--porcelain"]),
    "worktree " <> tree,
  )

  // Only the two new refs differ, and no existing ref moved.
  let after = state_rig.refs(scenario.receiver)
  let added =
    list.filter(string.split(after, "\n"), fn(line) {
      !list.contains(string.split(before, "\n"), line)
    })
  assert list.sort(added, string.compare)
    == [
      "refs/heads/loom/" <> session <> " " <> scenario.state.tip,
      "refs/loom/in/"
        <> state_object.short(scenario.state.hash)
        <> " "
        <> scenario.state.tip,
    ]
  assert list.all(string.split(before, "\n"), fn(line) {
    list.contains(string.split(after, "\n"), line)
  })

  // The receiver's own checkout, branch and index are untouched.
  assert worktree_rig.git(scenario.receiver, ["rev-parse", "HEAD"])
    == head_before
  assert index_of(scenario.receiver) == index_before
  assert worktree_rig.git(scenario.receiver, ["status", "--porcelain"]) == ""
  state_rig.stop(rig)
}

pub fn a_second_session_shares_the_import_of_the_same_state_test() {
  let scenario = scenario("apply-twice")
  let rig = scenario.rig
  let assert Ok(first) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      placement(scenario, 1),
    )
  let refs_between = state_rig.refs(scenario.receiver)
  let assert Ok(second) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      placement(scenario, 2),
    )
  assert second.ref == first.ref
  assert second.branch != first.branch
  assert worktree_rig.git(second.destination, ["rev-parse", "HEAD"])
    == scenario.state.tip

  // The second apply added one branch and no other ref.
  let added =
    list.filter(string.split(state_rig.refs(scenario.receiver), "\n"), fn(line) {
      !list.contains(string.split(refs_between, "\n"), line)
    })
  assert added == ["refs/heads/" <> second.branch <> " " <> scenario.state.tip]
  state_rig.stop(rig)
}

pub fn a_hostile_config_and_hooks_in_the_receiver_never_run_test() {
  let scenario = scenario("apply-hostile")
  let rig = scenario.rig
  let repository = scenario.receiver
  let hooks = repository <> "/.git/hooks"
  let canary = fn(name: String) { repository <> "/.git/" <> name }

  // Every hook the apply could trigger, a program for core.fsmonitor and a
  // rewrite of every path to an ext transport, all of which write a canary into
  // the one place the sandbox lets Git write.
  list.each(
    ["post-checkout", "reference-transaction", "post-merge", "pre-auto-gc"],
    fn(hook) {
      worktree_rig.write(
        hooks <> "/" <> hook,
        "#!/bin/sh\nprintf ran > '" <> canary("hook-ran") <> "'\nexit 0\n",
      )
      let assert Ok(Nil) =
        simplifile.set_permissions_octal(hooks <> "/" <> hook, 0o755)
    },
  )
  let fsmonitor = repository <> "/.git/fsmonitor-program"
  worktree_rig.write(
    fsmonitor,
    "#!/bin/sh\nprintf ran > '" <> canary("fsmonitor-ran") <> "'\nexit 0\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(fsmonitor, 0o755)
  let transport = repository <> "/.git/evil-transport"
  worktree_rig.write(
    transport,
    "#!/bin/sh\nprintf ran > '" <> canary("transport-ran") <> "'\nexit 1\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(transport, 0o755)
  let _ = worktree_rig.git(repository, ["config", "core.hooksPath", hooks])
  let _ = worktree_rig.git(repository, ["config", "core.fsmonitor", fsmonitor])
  let _ =
    worktree_rig.git(repository, ["config", "protocol.ext.allow", "always"])
  let _ =
    worktree_rig.git(repository, [
      "config",
      "url.ext::" <> transport <> " .insteadOf",
      "/",
    ])

  // Controls: without the override Git does run them, here in the operator's
  // own commands, so a missing canary below is the apply's doing.
  let control = rig.scratch <> "/control"
  let _ =
    worktree_rig.git(repository, [
      "-c",
      "core.hooksPath=" <> hooks,
      "worktree",
      "add",
      "--quiet",
      "--detach",
      control,
      "HEAD",
    ])
  assert simplifile.is_file(canary("hook-ran")) == Ok(True)
  let _ = worktree_rig.git(repository, ["status", "--porcelain"])
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(True)
  let #(_, _) =
    worktree_rig.git_status(repository, [
      "fetch",
      "--quiet",
      scenario.bundle,
      "refs/loom/snapshot:refs/loom/control",
    ])
  assert simplifile.is_file(canary("transport-ran")) == Ok(True)
  list.each(["hook-ran", "fsmonitor-ran", "transport-ran"], fn(name) {
    let assert Ok(Nil) = simplifile.delete(canary(name))
  })
  let _ =
    worktree_rig.git(repository, ["worktree", "remove", "--force", control])
  let _ =
    worktree_rig.git(repository, ["update-ref", "-d", "refs/loom/control"])

  let assert Ok(applied) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      placement(scenario, 1),
    )
  assert worktree_rig.git(applied.destination, ["rev-parse", "HEAD"])
    == scenario.state.tip
  assert simplifile.is_file(canary("hook-ran")) == Ok(False)
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(False)
  assert simplifile.is_file(canary("transport-ran")) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_wrong_hash_is_refused_before_the_repository_is_touched_test() {
  let scenario = scenario("apply-hash")
  let rig = scenario.rig
  let before = state_rig.refs(scenario.receiver)
  let wrong_digit = case string.slice(scenario.state.hash, 0, 1) {
    "0" -> "1"
    _ -> "0"
  }
  let wrong =
    State(
      ..scenario.state,
      hash: wrong_digit <> string.drop_start(scenario.state.hash, 1),
    )
  assert state_apply.apply(
      rig.git,
      scenario.bundle,
      wrong,
      placement(scenario, 1),
    )
    == Error("the bundle's SHA-256 is not the state's hash")

  // A declared size that is not the file's is refused as well, either way.
  let longer = State(..scenario.state, size: scenario.state.size + 1)
  let assert Error(_) =
    state_apply.apply(rig.git, scenario.bundle, longer, placement(scenario, 1))
  let shorter = State(..scenario.state, size: scenario.state.size - 1)
  let assert Error(_) =
    state_apply.apply(rig.git, scenario.bundle, shorter, placement(scenario, 1))
  assert state_rig.refs(scenario.receiver) == before
  assert simplifile.is_directory(destination(rig, 1)) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_truncated_bundle_is_refused_and_leaves_no_ref_test() {
  let scenario = scenario("apply-truncated")
  let rig = scenario.rig
  let before = state_rig.refs(scenario.receiver)
  let assert Ok(bytes) = simplifile.read_bits(scenario.bundle)
  let assert Ok(cut) =
    bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 40)
  let path = doctored(rig, "cut.bundle", cut)

  // The description of the whole file does not describe the cut one.
  let assert Error(reason) =
    state_apply.apply(rig.git, path, scenario.state, placement(scenario, 1))
  assert string.contains(reason, "bytes but the state declares")

  // A description recomputed over the cut bytes agrees with them, so the pack is
  // what Git has to refuse, and nothing is named or checked out.
  let honest = state_for(cut, scenario.state)
  let assert Error(unpacked) =
    state_apply.apply(rig.git, path, honest, placement(scenario, 1))
  assert string.contains(unpacked, "git bundle")
  assert state_rig.refs(scenario.receiver) == before
  assert simplifile.is_directory(destination(rig, 1)) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_description_the_bundle_contradicts_is_refused_test() {
  let scenario = scenario("apply-lies")
  let rig = scenario.rig
  let before = state_rig.refs(scenario.receiver)
  let apply = fn(state: State) {
    state_apply.apply(rig.git, scenario.bundle, state, placement(scenario, 1))
  }
  assert apply(State(..scenario.state, tip: scenario.third))
    == Error("the bundle's ref is not the state's tip")
  assert apply(State(..scenario.state, base: None))
    == Error(
      "the state declares a full bundle but the bundle has prerequisites",
    )
  assert state_rig.refs(scenario.receiver) == before
  assert simplifile.is_directory(destination(rig, 1)) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_thin_state_is_refused_where_the_base_is_not_held_test() {
  let scenario = scenario("apply-nobase")
  let rig = scenario.rig
  let other = worktree_rig.repository(rig.scratch <> "/other")
  let before = state_rig.refs(other)
  let session = worktree_rig.session(1)
  let parent = rig.state <> "/worktrees/other"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(parent)
  let tree = parent <> "/" <> session
  let assert Error(reason) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      Worktree(repository: other, destination: tree, session:),
    )
  assert reason
    == "the repository does not hold the state's base commit " <> scenario.base
  assert state_rig.refs(other) == before
  assert simplifile.is_directory(tree) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_full_state_becomes_a_clone_in_a_plain_directory_test() {
  let rig = state_rig.rig("apply-clone")
  worktree_rig.write(rig.root <> "/README", "changed\n")
  worktree_rig.write(rig.root <> "/fresh.txt", "fresh\n")
  let snapshot = state_rig.capture(rig, "full", Full)
  let #(state, bundle) = stored(rig, snapshot)
  let parent = rig.scratch <> "/directory"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(parent)
  let session = worktree_rig.session(1)
  let child = parent <> "/" <> session

  let assert Ok(applied) =
    state_apply.apply(
      rig.git,
      bundle,
      state,
      Clone(destination: child, session:),
    )
  assert applied.branch == "loom/" <> session
  assert simplifile.read(child <> "/README") == Ok("changed\n")
  assert simplifile.read(child <> "/fresh.txt") == Ok("fresh\n")
  assert worktree_rig.git(child, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/" <> session
  assert worktree_rig.git(child, ["rev-parse", "HEAD"]) == state.tip
  assert worktree_rig.git(child, [
      "rev-parse",
      "refs/loom/in/" <> state_object.short(state.hash),
    ])
    == state.tip
  assert worktree_rig.git(child, ["status", "--porcelain"]) == ""
  state_rig.stop(rig)
}

pub fn a_thin_state_is_refused_for_a_plain_directory_test() {
  let scenario = scenario("apply-clone-thin")
  let rig = scenario.rig
  let parent = rig.scratch <> "/directory"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(parent)
  let session = worktree_rig.session(1)
  let child = parent <> "/" <> session
  assert state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      Clone(destination: child, session:),
    )
    == Error(
      "a new repository holds no base commit, so it cannot take a thin state",
    )
  assert simplifile.is_directory(child) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_clone_that_fails_part_way_leaves_no_directory_test() {
  let rig = state_rig.rig("apply-clone-fail")
  worktree_rig.write(rig.root <> "/README", "changed\n")
  let snapshot = state_rig.capture(rig, "full", Full)
  let #(state, bundle) = stored(rig, snapshot)
  let assert Ok(bytes) = simplifile.read_bits(bundle)
  let assert Ok(cut) =
    bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 40)
  let path = doctored(rig, "cut.bundle", cut)
  let parent = rig.scratch <> "/directory"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(parent)
  let session = worktree_rig.session(1)
  let child = parent <> "/" <> session

  // The repository is made and then the unpack fails, and the directory goes.
  let assert Error(_) =
    state_apply.apply(
      rig.git,
      path,
      state_for(cut, state),
      Clone(destination: child, session:),
    )
  assert simplifile.is_directory(child) == Ok(False)
  state_rig.stop(rig)
}

pub fn placements_that_could_reach_beyond_their_grant_are_refused_test() {
  let scenario = scenario("apply-placements")
  let rig = scenario.rig
  let before = state_rig.refs(scenario.receiver)
  let session = worktree_rig.session(1)
  let tree = destination(rig, 1)
  let apply = fn(placement: state_apply.Placement) {
    state_apply.apply(rig.git, scenario.bundle, scenario.state, placement)
  }

  assert apply(Worktree(scenario.receiver, tree, "../escape"))
    == Error("the session name is not usable as a branch name")
  assert apply(Worktree(scenario.receiver, "relative/tree", session))
    == Error("the destination exists or is not an absolute path")
  assert apply(Worktree(
      scenario.receiver,
      rig.state <> "/worktrees/receiver/../x",
      session,
    ))
    == Error("the destination exists or is not an absolute path")
  assert apply(Worktree(
      scenario.receiver,
      scenario.receiver <> "/inside",
      session,
    ))
    == Error("the destination is inside the repository")
  assert apply(Worktree(scenario.receiver, scenario.receiver, session))
    == Error("the destination exists or is not an absolute path")
  let assert Error(not_a_checkout) = apply(Worktree(rig.scratch, tree, session))
  assert string.contains(not_a_checkout, "not a canonical primary checkout")
  assert state_rig.refs(scenario.receiver) == before
  assert simplifile.is_directory(tree) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_linked_worktree_is_not_a_repository_to_apply_into_test() {
  let scenario = scenario("apply-linked")
  let rig = scenario.rig
  let linked = rig.scratch <> "/linked"
  let _ =
    worktree_rig.git(scenario.receiver, [
      "worktree", "add", "--quiet", "--detach", linked, "HEAD",
    ])
  let assert Ok(linked) = bootstrap.canonical_directory(linked)
  let session = worktree_rig.session(1)
  let assert Error(reason) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      Worktree(linked, destination(rig, 1), session),
    )
  assert string.contains(reason, "not a canonical primary checkout")
  state_rig.stop(rig)
}

pub fn an_existing_ref_or_branch_is_never_moved_test() {
  let scenario = scenario("apply-existing")
  let rig = scenario.rig
  let incoming = state_object.incoming_ref(scenario.state.hash)
  let session = worktree_rig.session(1)

  // The incoming ref already names another commit: refused and untouched.
  let _ =
    worktree_rig.git(scenario.receiver, ["update-ref", incoming, scenario.base])
  assert state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      placement(scenario, 1),
    )
    == Error(incoming <> " already names a different commit")
  assert worktree_rig.git(scenario.receiver, ["rev-parse", incoming])
    == scenario.base
  let _ = worktree_rig.git(scenario.receiver, ["update-ref", "-d", incoming])

  // The session's branch exists already: Git refuses the name, and the branch
  // stays where it was. The incoming ref the state made remains, harmlessly.
  let branch = "refs/heads/loom/" <> session
  let _ =
    worktree_rig.git(scenario.receiver, ["update-ref", branch, scenario.base])
  let assert Error(reason) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      placement(scenario, 1),
    )
  assert string.contains(reason, "git worktree add")
  assert worktree_rig.git(scenario.receiver, ["rev-parse", branch])
    == scenario.base
  assert simplifile.is_directory(destination(rig, 1)) == Ok(False)
  state_rig.stop(rig)
}

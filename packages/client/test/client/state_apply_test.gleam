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
import support/internal/ffi_proc
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
  // The base commit's subject is not ASCII. It travels in the bundle header.
  let base =
    state_rig.commit_file(
      rig.root,
      "two",
      "two\n",
      "Fix \u{2014} the \u{e9} thing",
    )
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

// A source whose last commit merges a side branch that forked from the first
// commit, thin against the second. The receiver holds the first two, and the
// bundle's prerequisites are the second commit and the first. The first is
// read by the unpack and not by the check that the base is held.
fn merge_scenario(name: String) -> Scenario {
  let rig = state_rig.rig(name)
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let c2 = state_rig.commit_file(rig.root, "two", "two\n", "second")
  let receiver = state_rig.clone(rig, "receiver")
  let _ = worktree_rig.git(rig.root, ["checkout", "--quiet", "-b", "side", c1])
  let _ = state_rig.commit_file(rig.root, "side", "side\n", "side work")
  let _ = worktree_rig.git(rig.root, ["checkout", "--quiet", "main"])
  let _ =
    worktree_rig.git(rig.root, [
      "merge", "--quiet", "--no-ff", "side", "-m", "merge",
    ])
  let merged = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  worktree_rig.write(rig.root <> "/README", "dirty\n")
  let snapshot = state_rig.capture(rig, "thin", Thin(c2))
  let #(state, bundle) = stored(rig, snapshot)
  Scenario(rig:, receiver:, state:, bundle:, base: c2, third: merged)
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
    == Error("the destination's parent is not a canonical directory")
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

pub fn a_repository_whose_dot_git_is_a_link_is_refused_test() {
  let scenario = scenario("apply-dotgit-link")
  let rig = scenario.rig
  let before = state_rig.refs(scenario.receiver)

  // A directory that is canonical and whose `.git` points at the receiver's:
  // the writable root named from it would be resolved to somewhere else.
  let lookalike = rig.scratch <> "/lookalike"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(lookalike)
  let assert Ok(Nil) =
    simplifile.create_symlink(
      scenario.receiver <> "/.git",
      lookalike <> "/.git",
    )
  let assert Ok(lookalike) = bootstrap.canonical_directory(lookalike)
  let assert Error(reason) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      Worktree(lookalike, destination(rig, 1), worktree_rig.session(1)),
    )
  assert string.contains(reason, "not a canonical primary checkout")
  assert state_rig.refs(scenario.receiver) == before
  assert simplifile.is_directory(destination(rig, 1)) == Ok(False)
  state_rig.stop(rig)
}

pub fn a_missing_object_never_starts_a_promisor_transport_test() {
  let scenario = merge_scenario("apply-promisor")
  let rig = scenario.rig
  let repository = scenario.receiver
  let canary = repository <> "/.git/promisor-ran"
  let first =
    worktree_rig.git(repository, ["rev-list", "--max-parents=0", "HEAD"])

  // A receiver whose objects are loose, so that one can be deleted, and whose
  // config names a promisor remote reached by a command. The command writes a
  // canary into the one place the sandbox lets Git write, which is the
  // repository's `.git` for the unpack. The object deleted is the first commit,
  // which the bundle lists as a prerequisite and the base check never reads.
  let objects = repository <> "/.git/objects/pack"
  let held = rig.scratch <> "/held-packs"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(held)
  let assert Ok(names) = simplifile.read_directory(objects)
  list.each(names, fn(name) {
    let assert Ok(Nil) =
      simplifile.rename(objects <> "/" <> name, held <> "/" <> name)
  })
  let assert Ok(program) = ffi_proc.which("git")
  list.filter(names, string.ends_with(_, ".pack"))
  |> list.each(fn(name) {
    let assert Ok(#(0, _)) =
      ffi_proc.run(
        "/bin/sh",
        [
          "-c",
          "exec \"$0\" unpack-objects -q < \"$1\"",
          program,
          held <> "/" <> name,
        ],
        in: repository,
      )
  })
  let missing =
    repository
    <> "/.git/objects/"
    <> string.slice(first, 0, 2)
    <> "/"
    <> string.drop_start(first, 2)
  let assert Ok(Nil) = simplifile.delete(missing)

  let transport = repository <> "/.git/evil-transport"
  worktree_rig.write(
    transport,
    "#!/bin/sh\nprintf ran > '" <> canary <> "'\nexit 1\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(transport, 0o755)
  let _ =
    worktree_rig.git(repository, ["config", "core.repositoryformatversion", "1"])
  let _ =
    worktree_rig.git(repository, ["config", "extensions.partialClone", "evil"])
  let _ =
    worktree_rig.git(repository, [
      "config",
      "remote.evil.url",
      "ext::" <> transport,
    ])
  let _ =
    worktree_rig.git(repository, ["config", "remote.evil.promisor", "true"])
  let _ =
    worktree_rig.git(repository, [
      "config",
      "remote.evil.partialclonefilter",
      "blob:none",
    ])
  let _ =
    worktree_rig.git(repository, ["config", "protocol.ext.allow", "always"])

  // Control: an ordinary Git that unpacks the bundle reads the missing
  // prerequisite and starts the transport.
  let #(code, _) =
    worktree_rig.git_status(repository, ["bundle", "unbundle", scenario.bundle])
  assert code != 0
  assert simplifile.is_file(canary) == Ok(True)
  let assert Ok(Nil) = simplifile.delete(canary)

  // Apply reads the same missing object. The base it checks is held, so it gets
  // as far as the unpack, which Git refuses, and the transport never runs.
  let assert Error(reason) =
    state_apply.apply(
      rig.git,
      scenario.bundle,
      scenario.state,
      placement(scenario, 1),
    )
  assert string.contains(reason, "git bundle")
  assert simplifile.is_file(canary) == Ok(False)
  assert simplifile.is_directory(destination(rig, 1)) == Ok(False)
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

// --- Reset: the tree an executor's scope already has ------------------------

// The linked worktree an executor builds for a scope before anything is applied:
// made by the operator's own Git, on `loom/<session>`, at the receiver's head.
fn scope_tree(scenario: Scenario, session: Int) -> String {
  let tree = destination(scenario.rig, session)
  let branch = "loom/" <> worktree_rig.session(session)
  let _ =
    worktree_rig.git(scenario.receiver, [
      "worktree", "add", "--quiet", "-b", branch, tree, "HEAD",
    ])
  tree
}

fn reset(scenario: Scenario, session: Int) -> state_apply.Placement {
  state_apply.Reset(
    repository: scenario.receiver,
    worktree: destination(scenario.rig, session),
    session: worktree_rig.session(session),
  )
}

fn apply_reset(
  scenario: Scenario,
  session: Int,
) -> Result(state_apply.Applied, String) {
  state_apply.apply(
    scenario.rig.git,
    scenario.bundle,
    scenario.state,
    reset(scenario, session),
  )
}

pub fn an_existing_scope_tree_is_moved_onto_the_state_test() {
  let scenario = scenario("reset")
  let rig = scenario.rig
  let tree = scope_tree(scenario, 1)
  let session = worktree_rig.session(1)
  let before = state_rig.refs(scenario.receiver)
  let head_before = worktree_rig.git(scenario.receiver, ["rev-parse", "HEAD"])
  let index_before = index_of(scenario.receiver)

  let assert Ok(applied) = apply_reset(scenario, 1)
  assert applied.tip == scenario.state.tip
  assert applied.destination == tree
  assert applied.branch == "loom/" <> session
  assert applied.ref == state_object.incoming_ref(scenario.state.hash)

  // The dirty snapshot is checked out as committed content, untracked files
  // included, on the scope's own branch.
  assert simplifile.read(tree <> "/README") == Ok("dirty\n")
  assert simplifile.read(tree <> "/notes/new.txt") == Ok("untracked\n")
  assert simplifile.read(tree <> "/notes/deep/more.txt") == Ok("deeper\n")
  assert worktree_rig.git(tree, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/" <> session
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == scenario.state.tip
  assert worktree_rig.git(tree, ["status", "--porcelain"]) == ""

  // The branch moved and the incoming ref is new. Nothing else changed, and the
  // receiver's own checkout is as it was.
  let changed =
    list.filter(string.split(state_rig.refs(scenario.receiver), "\n"), fn(line) {
      !list.contains(string.split(before, "\n"), line)
    })
  assert list.sort(changed, string.compare)
    == [
      "refs/heads/loom/" <> session <> " " <> scenario.state.tip,
      "refs/loom/in/"
        <> state_object.short(scenario.state.hash)
        <> " "
        <> scenario.state.tip,
    ]
  assert worktree_rig.git(scenario.receiver, ["rev-parse", "HEAD"])
    == head_before
  assert index_of(scenario.receiver) == index_before
  assert worktree_rig.git(scenario.receiver, ["status", "--porcelain"]) == ""
  state_rig.stop(rig)
}

pub fn applying_into_the_same_tree_twice_changes_nothing_test() {
  let scenario = scenario("reset-twice")
  let rig = scenario.rig
  let tree = scope_tree(scenario, 1)
  let assert Ok(first) = apply_reset(scenario, 1)
  let refs = state_rig.refs(scenario.receiver)

  // A repeat finds the tip in the tree.
  assert apply_reset(scenario, 1) == Ok(first)
  assert state_rig.refs(scenario.receiver) == refs

  // The session has since committed on top and left an edit. A repeat that
  // arrives late must leave both alone.
  let child = state_rig.commit_file(tree, "child.txt", "child\n", "child work")
  worktree_rig.write(tree <> "/README", "child edit\n")
  assert apply_reset(scenario, 1) == Ok(first)
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == child
  assert simplifile.read(tree <> "/README") == Ok("child edit\n")
  state_rig.stop(rig)
}

pub fn a_scope_tree_with_changes_is_not_overwritten_test() {
  let scenario = scenario("reset-dirty")
  let rig = scenario.rig
  let tree = scope_tree(scenario, 1)
  let head = worktree_rig.git(tree, ["rev-parse", "HEAD"])

  // An untracked file is a change as much as an edit is.
  worktree_rig.write(tree <> "/mine.txt", "not yours to replace\n")
  let assert Error(reason) = apply_reset(scenario, 1)
  assert string.contains(reason, "holds changes")
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == head
  assert simplifile.read(tree <> "/mine.txt") == Ok("not yours to replace\n")

  // The objects and the incoming ref are in, which a later apply reuses, and no
  // branch moved.
  assert worktree_rig.git(scenario.receiver, [
      "rev-parse",
      "loom/" <> worktree_rig.session(1),
    ])
    == head
  state_rig.stop(rig)
}

pub fn a_tree_that_is_not_the_sessions_linked_worktree_is_refused_test() {
  let scenario = scenario("reset-wrong-tree")
  let rig = scenario.rig

  // A tree on another session's branch.
  let _ = scope_tree(scenario, 2)
  let wrong =
    state_apply.Reset(
      repository: scenario.receiver,
      worktree: destination(rig, 2),
      session: worktree_rig.session(1),
    )
  let assert Error(reason) =
    state_apply.apply(rig.git, scenario.bundle, scenario.state, wrong)
  assert string.contains(reason, "not the linked worktree")

  // A directory that is not a worktree at all, and one that does not exist.
  let plain = rig.scratch <> "/plain"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(plain)
  let assert Ok(plain) = bootstrap.canonical_directory(plain)
  let plain_reset =
    state_apply.Reset(
      repository: scenario.receiver,
      worktree: plain,
      session: worktree_rig.session(1),
    )
  let assert Error(_) =
    state_apply.apply(rig.git, scenario.bundle, scenario.state, plain_reset)
  let assert Error(_) = apply_reset(scenario, 3)

  // A worktree of another repository, on the right branch.
  let other = worktree_rig.repository(rig.scratch <> "/other")
  let strange = rig.state <> "/worktrees/receiver/strange"
  let _ =
    worktree_rig.git(other, [
      "worktree",
      "add",
      "--quiet",
      "-b",
      "loom/" <> worktree_rig.session(1),
      strange,
      "HEAD",
    ])
  let foreign =
    state_apply.Reset(
      repository: scenario.receiver,
      worktree: strange,
      session: worktree_rig.session(1),
    )
  let assert Error(_) =
    state_apply.apply(rig.git, scenario.bundle, scenario.state, foreign)

  // None of the refusals made the import: the state's incoming ref is absent.
  assert string.contains(state_rig.refs(scenario.receiver), "refs/loom/in/")
    == False
  state_rig.stop(rig)
}

pub fn a_tree_whose_dot_git_is_a_link_is_refused_test() {
  let scenario = scenario("reset-dotgit-link")
  let rig = scenario.rig
  let tree = scope_tree(scenario, 1)
  let before = state_rig.refs(scenario.receiver)

  // The tree's `.git` file is replaced by a link to the real one, which still
  // reads as a worktree to Git but is not the plain file the grant is made on.
  let real = rig.scratch <> "/real-dot-git"
  let assert Ok(Nil) = simplifile.rename(tree <> "/.git", real)
  let assert Ok(Nil) = simplifile.create_symlink(real, tree <> "/.git")
  let assert Error(reason) = apply_reset(scenario, 1)
  assert string.contains(reason, "plain .git file")
  assert state_rig.refs(scenario.receiver) == before
  state_rig.stop(rig)
}

pub fn hostile_configuration_cannot_change_a_reset_test() {
  let scenario = scenario("reset-hostile")
  let rig = scenario.rig
  let repository = scenario.receiver
  let tree = scope_tree(scenario, 1)
  let hooks = repository <> "/.git/hooks"
  let canary = fn(name: String) { repository <> "/.git/" <> name }

  // The hook the checkout would run and a program for core.fsmonitor, each of
  // which writes a canary into the one place the sandbox lets Git write.
  worktree_rig.write(
    hooks <> "/post-checkout",
    "#!/bin/sh\nprintf ran > '" <> canary("hook-ran") <> "'\nexit 0\n",
  )
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(hooks <> "/post-checkout", 0o755)
  let fsmonitor = repository <> "/.git/fsmonitor-program"
  worktree_rig.write(
    fsmonitor,
    "#!/bin/sh\nprintf ran > '" <> canary("fsmonitor-ran") <> "'\nexit 0\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(fsmonitor, 0o755)
  let _ = worktree_rig.git(repository, ["config", "core.hooksPath", hooks])
  let _ = worktree_rig.git(repository, ["config", "core.fsmonitor", fsmonitor])

  // Controls: ordinary Git run by the operator in the same tree starts both, so
  // a missing canary below is the apply's doing. The helper turns hooks off, so
  // the control turns them on again.
  let _ =
    worktree_rig.git(tree, [
      "-c",
      "core.hooksPath=" <> hooks,
      "checkout",
      "--quiet",
      "-b",
      "control",
      "HEAD",
    ])
  assert simplifile.is_file(canary("hook-ran")) == Ok(True)
  let _ = worktree_rig.git(tree, ["status", "--porcelain"])
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(True)
  list.each(["hook-ran", "fsmonitor-ran"], fn(name) {
    let assert Ok(Nil) = simplifile.delete(canary(name))
  })
  let _ =
    worktree_rig.git(tree, [
      "checkout",
      "--quiet",
      "loom/" <> worktree_rig.session(1),
    ])
  let _ = simplifile.delete(canary("fsmonitor-ran"))

  let assert Ok(applied) = apply_reset(scenario, 1)
  assert worktree_rig.git(applied.destination, ["rev-parse", "HEAD"])
    == scenario.state.tip
  assert simplifile.is_file(canary("hook-ran")) == Ok(False)
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(False)
  state_rig.stop(rig)
}

// A state a hostile peer made by hand: one commit on top of the receiver's head
// whose tree attaches a filter to every `.txt` file. Capture refuses such a
// tree, so it is built with the operator's Git and admitted as a transfer would.
// The answer is the source clone, the state and the stored bundle's path.
fn filtered_state(
  scenario: Scenario,
  name: String,
) -> #(String, State, String) {
  let rig = scenario.rig
  let source = rig.scratch <> "/" <> name
  let _ =
    worktree_rig.git(rig.scratch, [
      "clone",
      "--quiet",
      scenario.receiver,
      source,
    ])
  let base = worktree_rig.git(source, ["rev-parse", "HEAD"])
  worktree_rig.write(source <> "/.gitattributes", "*.txt filter=evil\n")
  worktree_rig.write(source <> "/payload.txt", "payload\n")
  let _ = worktree_rig.git(source, ["add", ".gitattributes", "payload.txt"])
  let _ = worktree_rig.git(source, ["commit", "--quiet", "-m", "attach"])
  let tip = worktree_rig.git(source, ["rev-parse", "HEAD"])
  let _ = worktree_rig.git(source, ["update-ref", state_object.bundle_ref, tip])

  // The bundle holds the one commit, thin against the head the receiver has.
  let bundle = rig.scratch <> "/" <> name <> ".bundle"
  let _ =
    worktree_rig.git(source, [
      "bundle",
      "create",
      bundle,
      state_object.bundle_ref,
      "^" <> base,
    ])
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(state) =
    state_store.put(
      store,
      bundle,
      tip:,
      base: Some(base),
      dirty: state_object.Clean,
      now_s: now(),
    )
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  #(source, held.state, held.path)
}

pub fn a_filter_only_a_linked_worktree_includes_does_not_run_test() {
  let scenario = scenario("apply-include")
  let rig = scenario.rig
  let repository = scenario.receiver
  let #(source, state, bundle) = filtered_state(scenario, "include-source")

  // A program that records that it ran in the one place the sandbox lets Git
  // write, and passes the bytes on.
  let marker = repository <> "/.git/smudge-ran"
  let program = rig.scratch <> "/smudge-program"
  worktree_rig.write(
    program,
    "#!/bin/sh\nprintf ran > '" <> marker <> "'\nexec cat\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(program, 0o755)

  // The driver is named by a file that only the Git directory of a linked
  // worktree includes, so the repository's own configuration lists none.
  let include = rig.scratch <> "/include.config"
  worktree_rig.write(
    include,
    "[filter \"evil\"]\n\tsmudge = " <> program <> "\n",
  )
  // The pattern names the `.git` directory too, because a checkout of the
  // repository may itself sit under a directory called `worktrees`.
  let key = "includeIf.gitdir:**/.git/worktrees/**.path"
  let _ = worktree_rig.git(repository, ["config", key, include])
  let _ = worktree_rig.git(source, ["config", key, include])
  let #(_, listed) =
    worktree_rig.git_status(repository, ["config", "--get-regexp", "^filter[.]"])
  assert !string.contains(listed, "filter.evil")

  // Control: the operator's Git adding a worktree of the same commit starts the
  // program, so a missing marker below is the apply's doing.
  let _ =
    worktree_rig.git(source, [
      "worktree",
      "add",
      "--quiet",
      "--detach",
      rig.scratch <> "/control",
      state.tip,
    ])
  assert simplifile.is_file(marker) == Ok(True)
  let assert Ok(Nil) = simplifile.delete(marker)

  let assert Ok(applied) =
    state_apply.apply(
      rig.git,
      bundle,
      state,
      Worktree(
        repository:,
        destination: destination(rig, 1),
        session: worktree_rig.session(1),
      ),
    )
  assert worktree_rig.git(applied.destination, ["rev-parse", "HEAD"])
    == state.tip
  assert simplifile.read(applied.destination <> "/payload.txt")
    == Ok("payload\n")
  assert simplifile.is_file(marker) == Ok(False)
  state_rig.stop(rig)
}

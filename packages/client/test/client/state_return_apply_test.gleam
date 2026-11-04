//// Applying the commits a remote child made, against real repositories and the
//// real sandbox helper (protocol-change/107, "Return").
////
//// A parent repository with uncommitted work is captured and sent; the "child"
//// is a repository made from that state, in which the test commits twice and
//// leaves an edit uncommitted; the child's commits are bundled thin against the
//// sent tip and stored by hash. The tests then apply that bundle into the
//// parent's repository and look at exactly what changed there, and at what a
//// wrong description, a bundle thin against something else, an existing ref and
//// a hostile configuration are not allowed to change.

import client/state_apply.{type Sent, AlreadyThere, Clone, Created, Sent}
import client/state_object.{type State, Full, State}
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
    store: state_store.Store,
    /// The state the parent sent, and where its bundle is.
    sent: Sent,
    /// The child's repository, which holds two commits and an uncommitted edit.
    child: String,
    /// The child's tip, the commit its work ended on.
    tip: String,
    /// The returned state and where its bundle is.
    returned: State,
    bundle: String,
  )
}

fn now() -> Int {
  bootstrap.system_time_ms() / 1000
}

fn store_of(rig: Rig) -> state_store.Store {
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  store
}

// Admits a bundle to the node's store and reads it back, which is the path a
// receiving node's apply takes.
fn stored(
  store: state_store.Store,
  path: String,
  tip: String,
  base: option.Option(String),
  dirty: state_object.Dirtiness,
) -> #(State, String) {
  let assert Ok(state) =
    state_store.put(store, path, tip:, base:, dirty:, now_s: now())
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  #(held.state, held.path)
}

// Bundles the commits after `base` in a repository, the way a receiver's capture
// would, under the one ref a state carries.
fn bundle_commits(repository: String, name: String, base: String) -> String {
  let _ =
    worktree_rig.git(repository, ["update-ref", state_object.bundle_ref, "HEAD"])
  let path = repository <> "/../" <> name <> ".bundle"
  let _ =
    worktree_rig.git(repository, [
      "bundle",
      "create",
      path,
      state_object.bundle_ref,
      "^" <> base,
    ])
  path
}

// A parent that sent its workspace, and a child that made two commits on top of
// the copy and left a third edit uncommitted. `parent` says whether the parent
// had uncommitted work when it sent, which makes the sent tip a snapshot commit
// the parent's repository has never held.
fn scenario(name: String, parent: state_object.Dirtiness) -> Scenario {
  let rig = state_rig.rig(name)
  case parent {
    state_object.Dirty -> {
      worktree_rig.write(rig.root <> "/README", "parent edit\n")
      worktree_rig.write(rig.root <> "/notes.txt", "untracked\n")
    }
    state_object.Clean -> Nil
  }
  let store = store_of(rig)
  let snapshot = state_rig.capture(rig, "sent", Full)
  let #(sent_state, sent_bundle) =
    stored(store, snapshot.bundle, snapshot.commit, None, snapshot.dirty)

  // The child's copy is made the way a receiving daemon makes it.
  let child = rig.scratch <> "/child"
  let assert Ok(_applied) =
    state_apply.apply(
      rig.git,
      sent_bundle,
      sent_state,
      Clone(destination: child, session: "seed-0123456789abcdef"),
    )
  let _ = state_rig.commit_file(child, "first.txt", "one\n", "child one")
  let tip = state_rig.commit_file(child, "second.txt", "two\n", "child two")
  worktree_rig.write(child <> "/README", "never committed\n")

  let bundle = bundle_commits(child, "returned", sent_state.tip)
  let #(returned, held) =
    stored(store, bundle, tip, Some(sent_state.tip), state_object.Clean)
  Scenario(
    rig:,
    store:,
    sent: Sent(bundle: sent_bundle, state: sent_state),
    child:,
    tip:,
    returned:,
    bundle: held,
  )
}

fn index_of(repository: String) -> BitArray {
  let assert Ok(bytes) = simplifile.read_bits(repository <> "/.git/index")
  bytes
}

fn child_name() -> String {
  "sub:^main/finish-the-cache-0123456789abcdef"
}

fn ref_of(scenario: Scenario) -> String {
  "refs/loom/children/finish-the-cache-0123456789abcdef/"
  <> string.slice(scenario.tip, 0, 8)
}

fn apply(scenario: Scenario) {
  state_apply.apply_returned(
    scenario.rig.git,
    scenario.rig.root,
    child_name(),
    scenario.sent,
    scenario.bundle,
    scenario.returned,
  )
}

// The lines of `refs` output that are not in `before`.
fn added(before: String, after: String) -> List(String) {
  list.filter(string.split(after, "\n"), fn(line) {
    !list.contains(string.split(before, "\n"), line)
  })
}

pub fn a_childs_commits_come_back_as_one_ref_and_nothing_else_moves_test() {
  let scenario = scenario("return-dirty", state_object.Dirty)
  let rig = scenario.rig
  let before = state_rig.refs(rig.root)
  let head_before = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let index_before = index_of(rig.root)
  let status_before = worktree_rig.git(rig.root, ["status", "--porcelain"])
  let readme_before = simplifile.read(rig.root <> "/README")

  let assert Ok(returned) = apply(scenario)
  assert returned.ref == ref_of(scenario)
  assert returned.tip == scenario.tip
  assert returned.creation == Created

  // Exactly one ref is new, it names the child's tip, and the two commits the
  // child made are on it above the sent snapshot.
  assert added(before, state_rig.refs(rig.root))
    == [ref_of(scenario) <> " " <> scenario.tip]
  assert worktree_rig.git(rig.root, [
      "rev-list",
      "--count",
      scenario.tip,
      "^" <> scenario.sent.state.tip,
    ])
    == "2"
  assert worktree_rig.git(rig.root, ["log", "-1", "--format=%s", scenario.tip])
    == "child two"
  assert worktree_rig.git(rig.root, [
      "show",
      scenario.tip <> ":second.txt",
    ])
    == "two"

  // The uncommitted edit stayed in the child, and the parent's checkout, branch,
  // index and tree are what they were.
  assert worktree_rig.git(rig.root, ["show", scenario.tip <> ":README"])
    == "parent edit"
  assert worktree_rig.git(rig.root, ["rev-parse", "HEAD"]) == head_before
  assert index_of(rig.root) == index_before
  assert worktree_rig.git(rig.root, ["status", "--porcelain"]) == status_before
  assert simplifile.read(rig.root <> "/README") == readme_before
  state_rig.stop(rig)
}

pub fn a_clean_sent_state_needs_no_unpack_of_the_sent_bundle_test() {
  let scenario = scenario("return-clean", state_object.Clean)
  let rig = scenario.rig
  let before = state_rig.refs(rig.root)

  // The sent tip is the parent's own HEAD, so the repository holds it already.
  assert scenario.sent.state.dirty == state_object.Clean
  assert scenario.sent.state.tip
    == worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let assert Ok(returned) = apply(scenario)
  assert returned.creation == Created
  assert added(before, state_rig.refs(rig.root))
    == [ref_of(scenario) <> " " <> scenario.tip]
  state_rig.stop(rig)
}

pub fn a_replayed_return_changes_nothing_and_is_not_an_error_test() {
  let scenario = scenario("return-replay", state_object.Dirty)
  let rig = scenario.rig
  let assert Ok(first) = apply(scenario)
  assert first.creation == Created
  let refs = state_rig.refs(rig.root)

  let assert Ok(again) = apply(scenario)
  assert again.ref == first.ref
  assert again.tip == first.tip
  assert again.creation == AlreadyThere
  assert state_rig.refs(rig.root) == refs
  state_rig.stop(rig)
}

pub fn a_ref_that_names_another_commit_is_refused_and_left_alone_test() {
  let scenario = scenario("return-taken", state_object.Dirty)
  let rig = scenario.rig
  let head = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let _ = worktree_rig.git(rig.root, ["update-ref", ref_of(scenario), head])
  let before = state_rig.refs(rig.root)

  let assert Error(reason) = apply(scenario)
  assert string.contains(reason, "already names a different commit")
  assert state_rig.refs(rig.root) == before
  state_rig.stop(rig)
}

pub fn a_bundle_thin_against_anything_but_the_sent_tip_is_refused_test() {
  let scenario = scenario("return-other-base", state_object.Dirty)
  let rig = scenario.rig
  let before = state_rig.refs(rig.root)

  // Thin against the first commit of the child's history, which is the sent
  // snapshot's parent, so the header lists that commit and not the sent tip.
  let older = worktree_rig.git(scenario.child, ["rev-parse", "HEAD~3"])
  let bundle = bundle_commits(scenario.child, "wider", older)
  let #(wider, held) =
    stored(
      scenario.store,
      bundle,
      scenario.tip,
      Some(older),
      state_object.Clean,
    )
  let assert Error(reason) =
    state_apply.apply_returned(
      rig.git,
      rig.root,
      child_name(),
      scenario.sent,
      held,
      wider,
    )
  assert string.contains(reason, "not thin against the state that was sent")

  // The same bundle described as thin against the sent tip is caught by the
  // header, which lists another commit.
  let lying = State(..wider, base: Some(scenario.sent.state.tip))
  let assert Error(second) =
    state_apply.apply_returned(
      rig.git,
      rig.root,
      child_name(),
      scenario.sent,
      held,
      lying,
    )
  assert string.contains(second, "other than the state that was sent")
  assert state_rig.refs(rig.root) == before
  state_rig.stop(rig)
}

pub fn a_description_that_does_not_match_the_bytes_is_refused_early_test() {
  let scenario = scenario("return-lies", state_object.Dirty)
  let rig = scenario.rig
  let before = state_rig.refs(rig.root)
  let apply_with = fn(returned: State) {
    state_apply.apply_returned(
      rig.git,
      rig.root,
      child_name(),
      scenario.sent,
      scenario.bundle,
      returned,
    )
  }

  // A hash that is not the bytes', a size that is not the file's, a size over
  // the limit, and a tip the bundle does not carry.
  let assert Error(_) =
    apply_with(State(..scenario.returned, hash: string.repeat("a", 64)))
  let assert Error(_) =
    apply_with(State(..scenario.returned, size: scenario.returned.size + 1))
  let assert Error("the state is over the size limit") =
    apply_with(State(..scenario.returned, size: state_object.size_limit + 1))
  let assert Error(_) =
    apply_with(State(..scenario.returned, tip: scenario.sent.state.tip))
  assert state_rig.refs(rig.root) == before
  state_rig.stop(rig)
}

pub fn a_truncated_bundle_is_refused_before_a_repository_is_opened_test() {
  let scenario = scenario("return-cut", state_object.Dirty)
  let rig = scenario.rig
  let before = state_rig.refs(rig.root)
  let assert Ok(bytes) = simplifile.read_bits(scenario.bundle)
  let assert Ok(cut) = bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 7)
  let path = rig.scratch <> "/cut.bundle"
  let assert Ok(Nil) = simplifile.write_bits(path, cut)

  // Described by the whole file's hash and size, the short file fails both.
  let assert Error(_) =
    state_apply.apply_returned(
      rig.git,
      rig.root,
      child_name(),
      scenario.sent,
      path,
      scenario.returned,
    )

  // Described by its own hash and size, the header cannot be trusted either:
  // the pack is short, so the unpack or the walk refuses it and no ref is made.
  let own =
    State(
      ..scenario.returned,
      hash: state_object.hash_of(cut),
      size: bit_array.byte_size(cut),
    )
  let assert Error(_) =
    state_apply.apply_returned(
      rig.git,
      rig.root,
      child_name(),
      scenario.sent,
      path,
      own,
    )
  assert state_rig.refs(rig.root) == before
  state_rig.stop(rig)
}

pub fn a_child_name_that_is_not_a_ref_component_is_refused_test() {
  let scenario = scenario("return-name", state_object.Dirty)
  let rig = scenario.rig
  let before = state_rig.refs(rig.root)

  // Each would reach outside `refs/loom/children/` or is not a valid ref.
  list.each(
    [
      "sub:^main/..",
      "sub:^main/a..b",
      "sub:^main/x.lock",
      "sub:^main/UPPER",
      "sub:^main/a:b",
      "sub:^main/",
      "",
    ],
    fn(name) {
      let assert Error(_) =
        state_apply.apply_returned(
          rig.git,
          rig.root,
          name,
          scenario.sent,
          scenario.bundle,
          scenario.returned,
        )
      Nil
    },
  )
  assert state_rig.refs(rig.root) == before
  state_rig.stop(rig)
}

pub fn a_repository_that_is_not_a_canonical_checkout_is_refused_test() {
  let scenario = scenario("return-repository", state_object.Dirty)
  let rig = scenario.rig
  let link = rig.scratch <> "/link"
  let assert Ok(Nil) = simplifile.create_symlink(rig.root, link)
  let before = state_rig.refs(rig.root)

  let assert Error(_) =
    state_apply.apply_returned(
      rig.git,
      link,
      child_name(),
      scenario.sent,
      scenario.bundle,
      scenario.returned,
    )
  let assert Error(_) =
    state_apply.apply_returned(
      rig.git,
      rig.scratch,
      child_name(),
      scenario.sent,
      scenario.bundle,
      scenario.returned,
    )
  assert state_rig.refs(rig.root) == before
  state_rig.stop(rig)
}

pub fn a_hostile_config_and_hooks_in_the_parent_never_run_test() {
  let scenario = scenario("return-hostile", state_object.Dirty)
  let rig = scenario.rig
  let repository = rig.root
  let hooks = repository <> "/.git/hooks"
  let canary = fn(name: String) { repository <> "/.git/" <> name }

  // Hooks the update could trigger, and a file-system monitor, each of which
  // writes a canary into the one place the sandbox lets Git write.
  list.each(["reference-transaction", "post-checkout", "pre-auto-gc"], fn(hook) {
    worktree_rig.write(
      hooks <> "/" <> hook,
      "#!/bin/sh\nprintf ran > '" <> canary("hook-ran") <> "'\nexit 0\n",
    )
    let assert Ok(Nil) =
      simplifile.set_permissions_octal(hooks <> "/" <> hook, 0o755)
  })
  let fsmonitor = repository <> "/.git/fsmonitor-program"
  worktree_rig.write(
    fsmonitor,
    "#!/bin/sh\nprintf ran > '" <> canary("fsmonitor-ran") <> "'\nexit 0\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(fsmonitor, 0o755)
  let _ = worktree_rig.git(repository, ["config", "core.hooksPath", hooks])
  let _ = worktree_rig.git(repository, ["config", "core.fsmonitor", fsmonitor])

  // Controls: Git does run them when the operator's own command allows it, so a
  // missing canary below is the apply's doing.
  let _ =
    worktree_rig.git(repository, [
      "-c",
      "core.hooksPath=" <> hooks,
      "update-ref",
      "refs/loom/control",
      "HEAD",
    ])
  assert simplifile.is_file(canary("hook-ran")) == Ok(True)
  let _ = worktree_rig.git(repository, ["status", "--porcelain"])
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(True)
  list.each(["hook-ran", "fsmonitor-ran"], fn(name) {
    let assert Ok(Nil) = simplifile.delete(canary(name))
  })
  let _ =
    worktree_rig.git(repository, ["update-ref", "-d", "refs/loom/control"])

  let assert Ok(returned) = apply(scenario)
  assert returned.creation == Created
  assert simplifile.is_file(canary("hook-ran")) == Ok(False)
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(False)
  state_rig.stop(rig)
}

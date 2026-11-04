//// Thin capture against a real repository and the real sandbox helper
//// (protocol-change/107, "Capture"): the candidates a sender offers, a bundle of
//// only what a receiver lacks, the fallback to a full bundle, and a clean tree
//// whose tip is `HEAD`.

import client/git_identity
import client/repository_snapshot
import client/state_object.{Clean, Dirty, Full, Thin}
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import simplifile
import support/state_rig
import support/worktree_rig

const unknown = "0123456789abcdef0123456789abcdef01234567"

// The base commit's subject goes into the bundle header after its id, in the
// raw UTF-8 the author wrote, so the thin tests use one that is not ASCII.
const subject = "Fix \u{2014} the \u{e9} thing"

fn header_of(path: String) -> state_object.Header {
  let assert Ok(bytes) = simplifile.read_bits(path)
  let assert Ok(header) = state_object.parse_header(bytes)
  header
}

// Whether the needle appears in the bytes at or after the offset.
fn contains_bytes(bytes: BitArray, needle: BitArray, from: Int) -> Bool {
  case bit_array.slice(bytes, from, bit_array.byte_size(needle)) {
    Ok(window) if window == needle -> True
    Ok(_) -> contains_bytes(bytes, needle, from + 1)
    Error(Nil) -> False
  }
}

fn size_of(path: String) -> Int {
  let assert Ok(bytes) = simplifile.read_bits(path)
  bit_array.byte_size(bytes)
}

// A file whose text does not compress, so a bundle that carries it is large.
fn incompressible() -> String {
  crypto.strong_random_bytes(100_000) |> bit_array.base16_encode
}

pub fn candidates_are_head_and_its_first_parents_test() {
  let rig = state_rig.rig("candidates")
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let c2 = state_rig.commit_file(rig.root, "two", "two\n", "second")
  let c3 = state_rig.commit_file(rig.root, "three", "three\n", "third")
  assert repository_snapshot.base_candidates(rig.git, rig.call, 30_000)
    == Ok([c3, c2, c1])
  state_rig.stop(rig)
}

pub fn candidates_are_limited_and_end_with_the_upstream_merge_base_test() {
  let rig = state_rig.rig("candidates-upstream")
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let _trunk = worktree_rig.git(rig.root, ["branch", "trunk", c1])
  let _remote =
    worktree_rig.git(rig.root, ["config", "branch.main.remote", "."])
  let _merge =
    worktree_rig.git(rig.root, [
      "config",
      "branch.main.merge",
      "refs/heads/trunk",
    ])
  list.repeat(Nil, 20)
  |> list.index_map(fn(_, n) {
    let name = "file" <> int.to_string(n)
    state_rig.commit_file(rig.root, name, name, "commit " <> name)
    Nil
  })
  let head = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  assert worktree_rig.git(rig.root, ["rev-parse", "@{upstream}"]) == c1

  // Sixteen first-parent commits from HEAD, then the merge base, which is
  // further back than the chain reaches.
  let assert Ok(found) =
    repository_snapshot.base_candidates(rig.git, rig.call, 30_000)
  assert list.length(found) == 17
  assert list.first(found) == Ok(head)
  assert list.last(found) == Ok(c1)
  assert list.unique(found) == found
  state_rig.stop(rig)
}

pub fn a_thin_bundle_carries_only_what_the_receiver_lacks_test() {
  let rig = state_rig.rig("thin")
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let c2 = state_rig.commit_file(rig.root, "big.txt", incompressible(), subject)
  let receiver = state_rig.clone(rig, "receiver")
  let c3 = state_rig.commit_file(rig.root, "README", "three\n", "third")

  // Uncommitted work on top: a changed tracked file and a new untracked one.
  worktree_rig.write(rig.root <> "/README", "dirty\n")
  worktree_rig.write(rig.root <> "/notes/new.txt", "untracked\n")

  // The receiver reports the candidates it holds. It lacks c3.
  let assert Ok(candidates) =
    repository_snapshot.base_candidates(rig.git, rig.call, 30_000)
  assert candidates == [c3, c2, c1]
  let basis = state_object.choose_basis(candidates, [c2, c1])
  assert basis == Thin(c2)

  let thin = state_rig.capture(rig, "thin", basis)
  let full = state_rig.capture(rig, "full", Full)
  assert thin.base == Some(c2)
  assert thin.dirty == Dirty
  assert thin.commit != c3
  assert full.base == None
  assert full.commit != c3

  // The thin bundle leaves out the large file the receiver already holds.
  assert size_of(thin.bundle) * 2 < size_of(full.bundle)

  // The headers say the same thing the capture does.
  let thin_header = header_of(thin.bundle)

  // The subject really is in the header in bytes outside ASCII, so the parse
  // above read past it. The commit runner hands Git the text as Latin-1, so
  // the dash arrives as the UTF-8 of three Latin-1 characters, which starts
  // with the byte 195.
  let assert Ok(thin_bytes) = simplifile.read_bits(thin.bundle)
  let assert Ok(prefix) = bit_array.slice(thin_bytes, 0, 300)
  assert contains_bytes(prefix, <<195>>, 0)
  assert list.contains(thin_header.prerequisites, c2)
  assert thin_header.refs == [#(thin.commit, state_object.bundle_ref)]
  assert header_of(full.bundle).prerequisites == []
  let thin_state = state_rig.state_of(thin)
  assert state_object.verify_bundle(thin_state, thin_bytes) == Ok(Nil)

  // The verified child holds the working bytes, untracked files included.
  assert simplifile.read(thin.child <> "/README") == Ok("dirty\n")
  assert simplifile.read(thin.child <> "/notes/new.txt") == Ok("untracked\n")
  assert worktree_rig.git(thin.child, ["rev-parse", "HEAD"]) == thin.commit
  assert worktree_rig.git(thin.child, ["rev-parse", "HEAD^"]) == c3

  // An independent repository that holds the base verifies the bundle, and one
  // that does not, refuses it.
  let #(held_code, _) =
    worktree_rig.git_status(receiver, ["bundle", "verify", thin.bundle])
  assert held_code == 0
  let empty = rig.scratch <> "/empty"
  let _init = worktree_rig.git(rig.scratch, ["init", "--quiet", empty])
  let #(empty_code, _) =
    worktree_rig.git_status(empty, ["bundle", "verify", thin.bundle])
  assert empty_code != 0
  state_rig.stop(rig)
}

pub fn uncommitted_work_thin_against_head_ships_one_commit_test() {
  let rig = state_rig.rig("thin-head")
  let _big =
    state_rig.commit_file(rig.root, "big.txt", incompressible(), subject)
  let head = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  worktree_rig.write(rig.root <> "/README", "dirty\n")

  // The common case of a child handed its parent's work: the receiver holds
  // HEAD, so the bundle is the snapshot commit and what it adds.
  let full = state_rig.capture(rig, "full", Full)
  let thin = state_rig.capture(rig, "thin", Thin(head))
  assert thin.dirty == Dirty
  assert thin.base == Some(head)
  assert worktree_rig.git(thin.child, ["rev-parse", "HEAD^"]) == head
  assert header_of(thin.bundle).prerequisites == [head]
  assert size_of(thin.bundle) * 10 < size_of(full.bundle)
  state_rig.stop(rig)
}

pub fn a_merge_after_the_base_has_prerequisites_beyond_the_base_test() {
  let rig = state_rig.rig("thin-merge")
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let _side = worktree_rig.git(rig.root, ["checkout", "--quiet", "-b", "side"])
  let _s1 = state_rig.commit_file(rig.root, "side.txt", "side\n", "side work")
  let _main = worktree_rig.git(rig.root, ["checkout", "--quiet", "main"])
  let c2 = state_rig.commit_file(rig.root, "main.txt", "main\n", "main work")
  let _merged =
    worktree_rig.git(rig.root, [
      "merge",
      "--quiet",
      "--no-ff",
      "side",
      "-m",
      "merge",
    ])

  // The receiver holds c2 and so c1. The merge brings the side commit in, whose
  // parent c1 is a boundary of the bundle as well.
  let snapshot = state_rig.capture(rig, "merge", Thin(c2))
  assert snapshot.dirty == Clean
  let header = header_of(snapshot.bundle)
  assert list.contains(header.prerequisites, c2)
  assert list.contains(header.prerequisites, c1)
  let assert Ok(bytes) = simplifile.read_bits(snapshot.bundle)
  assert state_object.verify_bundle(state_rig.state_of(snapshot), bytes)
    == Ok(Nil)
  state_rig.stop(rig)
}

pub fn a_receiver_that_holds_nothing_gets_a_full_bundle_test() {
  let rig = state_rig.rig("full-fallback")
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let c2 = state_rig.commit_file(rig.root, "two", "two\n", "second")
  let assert Ok(candidates) =
    repository_snapshot.base_candidates(rig.git, rig.call, 30_000)
  assert candidates == [c2, c1]

  // The receiver reports a commit the source never offered, which holds none of
  // the candidates, so the choice is a full bundle and capture makes one.
  let basis = state_object.choose_basis(candidates, [unknown])
  assert basis == Full
  let snapshot = state_rig.capture(rig, "fallback", basis)
  assert snapshot.base == None
  assert header_of(snapshot.bundle).prerequisites == []
  state_rig.stop(rig)
}

pub fn a_base_the_source_cannot_bundle_against_is_refused_before_a_stage_test() {
  let rig = state_rig.rig("bad-base")
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let _side = worktree_rig.git(rig.root, ["checkout", "--quiet", "-b", "side"])
  let s1 = state_rig.commit_file(rig.root, "side.txt", "side\n", "side work")
  let _main = worktree_rig.git(rig.root, ["checkout", "--quiet", "main"])
  let _c2 = state_rig.commit_file(rig.root, "two", "two\n", "second")

  assert state_rig.try_capture(rig, "unknown", Thin(unknown))
    == Error("the thin base is not a commit in the source repository")
  assert state_rig.try_capture(rig, "named", Thin("HEAD"))
    == Error("the thin base is not a full object id")
  assert state_rig.try_capture(rig, "option", Thin("--upload-pack=x"))
    == Error("the thin base is not a full object id")
  assert state_rig.try_capture(rig, "side", Thin(s1))
    == Error("the thin base is not an ancestor of the source HEAD")

  // None of them got far enough to make a stage, and the source is as it was.
  list.each(["unknown", "named", "option", "side"], fn(name) {
    assert simplifile.is_directory(rig.snapshots <> "/" <> name) == Ok(False)
  })
  assert worktree_rig.git(rig.root, ["status", "--porcelain"]) == ""
  let _ = c1
  state_rig.stop(rig)
}

pub fn a_clean_tree_delivers_head_itself_and_needs_no_identity_test() {
  let rig = state_rig.rig("clean")
  let c1 = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let c2 = state_rig.commit_file(rig.root, "two", "two\n", "second")

  // No difference from HEAD, so no snapshot commit, and no author to need.
  let assert Ok(snapshot) =
    repository_snapshot.capture_against(
      rig.git,
      rig.call,
      rig.snapshots,
      "no-identity",
      git_identity.Identity(None, None),
      120_000,
      Full,
    )
  assert snapshot.dirty == Clean
  assert snapshot.commit == c2
  assert snapshot.base == None
  assert worktree_rig.git(snapshot.child, ["rev-parse", "HEAD"]) == c2

  // Thin against an ancestor still ships what follows it.
  let thin = state_rig.capture(rig, "clean-thin", Thin(c1))
  assert thin.commit == c2
  assert thin.base == Some(c1)

  // Thin against HEAD itself leaves nothing to ship, which Git cannot bundle.
  assert state_rig.try_capture(rig, "nothing", Thin(c2))
    == Error(
      "the receiver already holds the clean tip, so there is nothing to bundle",
    )
  state_rig.stop(rig)
}

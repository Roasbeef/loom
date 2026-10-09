//// Adoption of the blobs an earlier release kept in `<workspace>/.blobs`.
////
//// The store moved out of the workspace, but a transcript written before
//// the move names its artifacts by id. These tests drive the real
//// filesystem seam against a legacy directory laid out as the old release
//// left it, and assert what the new store holds afterwards.

import client/blobs
import client/internal/ffi_os
import gleam/int
import gleam/list
import gleam/string
import simplifile
import tools/blob
import tools/fs

pub fn a_legacy_blob_is_copied_after_its_digest_is_verified_test() {
  let #(legacy, store) = fresh("copied")
  let bytes = <<"an artifact a session wrote before the move":utf8>>
  let ref = blob.ref_for(bytes)
  write_bits(blob.ref_path(legacy, ref), bytes)

  let report = adopt(legacy, store)

  assert report.adopted == 1
  assert report.rejected == []
  assert simplifile.read_bits(blob.ref_path(store, ref)) == Ok(bytes)

  // The legacy directory is left alone: nothing of the user's is deleted.
  assert simplifile.read_bits(blob.ref_path(legacy, ref)) == Ok(bytes)
}

pub fn a_legacy_blob_whose_content_does_not_match_its_name_is_skipped_test() {
  let #(legacy, store) = fresh("corrupt")
  let genuine = <<"the bytes this name was minted for":utf8>>
  let ref = blob.ref_for(genuine)

  // A file under a real address with other bytes in it: a torn write, or
  // something a jailed tool put there once the directory stopped being
  // protected. It must not become an artifact.
  write_bits(blob.ref_path(legacy, ref), <<"substituted bytes":utf8>>)

  let report = adopt(legacy, store)

  assert report.adopted == 0
  assert list.map(report.rejected, fn(rejection) { rejection.name }) == [ref]
  assert simplifile.is_file(blob.ref_path(store, ref)) == Ok(False)
}

pub fn a_second_run_adopts_nothing_and_rewrites_nothing_test() {
  let #(legacy, store) = fresh("idempotent")
  let bytes = <<"adopted exactly once":utf8>>
  let ref = blob.ref_for(bytes)
  write_bits(blob.ref_path(legacy, ref), bytes)

  let first = adopt(legacy, store)
  assert first.adopted == 1

  // Replace the adopted file with a marker. A rewrite would restore the
  // genuine bytes, so finding the marker later proves the second pass
  // neither read nor wrote it.
  write_bits(blob.ref_path(store, ref), <<"marker":utf8>>)
  let second = adopt(legacy, store)

  assert second.adopted == 0
  assert second.already_present == 1
  assert second.rejected == []
  assert simplifile.read_bits(blob.ref_path(store, ref))
    == Ok(<<"marker":utf8>>)
}

pub fn only_address_shaped_names_are_considered_test() {
  let #(legacy, store) = fresh("shapes")
  let bytes = <<"the one real artifact":utf8>>
  let ref = blob.ref_for(bytes)
  write_bits(blob.ref_path(legacy, ref), bytes)

  // The ignore file the old release wrote, a staging file left by a crash,
  // a name with the wrong digit count and one in upper case are all things
  // a person or a crash left behind, never addresses.
  write_bits(legacy <> "/.gitignore", <<"*\n":utf8>>)
  write_bits(blob.temp_path(legacy, ref, "tag"), bytes)
  write_bits(legacy <> "/sha256-abc", <<"short":utf8>>)
  write_bits(legacy <> "/sha256-" <> string.repeat("A", 64), <<"upper":utf8>>)

  let report = adopt(legacy, store)

  assert report.adopted == 1
  assert report.rejected == []
  let assert Ok(names) = simplifile.read_directory(store)
  assert names == [ref]
}

pub fn a_symbolic_link_is_not_followed_test() {
  let #(legacy, store) = fresh("symlink")
  let bytes = <<"content that really does hash to the name":utf8>>
  let ref = blob.ref_for(bytes)
  let outside = legacy <> "-outside"
  write_bits(outside, bytes)

  // The link points at bytes that would pass the digest check, so only the
  // refusal to follow it keeps a link out of the store.
  let assert Ok(Nil) =
    simplifile.create_symlink(to: outside, from: blob.ref_path(legacy, ref))

  let report = adopt(legacy, store)

  assert report.adopted == 0
  assert list.map(report.rejected, fn(rejection) { rejection.name }) == [ref]
  assert simplifile.is_file(blob.ref_path(store, ref)) == Ok(False)
}

// A jailed tool can replace `.blobs` with a link to another workspace's
// store. Every file there hashes to its own name, so only refusing the
// linked directory itself keeps one workspace out of another's artifacts.
pub fn a_symbolic_link_in_place_of_the_legacy_directory_is_not_read_test() {
  let #(legacy, store) = fresh("linked-directory")
  let other_store = legacy <> "-other-workspace-store"
  let bytes = <<"an artifact that belongs to a different workspace":utf8>>
  let ref = blob.ref_for(bytes)
  let assert Ok(Nil) = simplifile.create_directory_all(other_store)
  write_bits(blob.ref_path(other_store, ref), bytes)

  // Put the link where the legacy directory was.
  let assert Ok(Nil) = simplifile.delete(legacy)
  let assert Ok(Nil) = simplifile.create_symlink(to: other_store, from: legacy)

  let report = adopt(legacy, store)

  assert report.adopted == 0
  assert list.length(report.rejected) == 1
  assert simplifile.is_file(blob.ref_path(store, ref)) == Ok(False)
  assert simplifile.is_directory(store) == Ok(False)
}

pub fn a_workspace_with_no_legacy_directory_is_a_no_op_test() {
  let #(legacy, store) = fresh("absent")
  let report = adopt(legacy <> "/missing", store)

  assert report == blobs.Report(0, 0, [], 0)

  // No store is created for nothing to put in it.
  assert simplifile.is_directory(store) == Ok(False)
}

pub fn the_pass_stops_at_its_deadline_and_a_later_pass_finishes_test() {
  let #(legacy, store) = fresh("deadline")
  let refs =
    list.map([1, 2, 3], fn(index) {
      let bytes = <<"blob number ":utf8, int.to_string(index):utf8>>
      write_bits(blob.ref_path(legacy, blob.ref_for(bytes)), bytes)
      blob.ref_for(bytes)
    })

  // The clock is already past the deadline when the first name is reached,
  // so the pass reports every name as unfinished and copies none.
  let late =
    blobs.adopt(
      legacy:,
      into: store,
      filesystem: fs.real_filesystem(),
      within_ms: 0,
      now: fn() { 1000 },
    )
  assert late.adopted == 0
  assert late.unfinished == 3

  // The next session start has a fresh budget and picks up where it left
  // off, with the same result a single unhurried pass would have had.
  let finished = adopt(legacy, store)
  assert finished.adopted == 3
  assert finished.unfinished == 0
  let assert Ok(names) = simplifile.read_directory(store)
  assert list.sort(names, string.compare) == list.sort(refs, string.compare)
}

fn adopt(legacy: String, store: String) -> blobs.Report {
  blobs.adopt(
    legacy:,
    into: store,
    filesystem: fs.real_filesystem(),
    within_ms: blobs.adoption_budget_ms,
    now: ffi_os.system_time_ms,
  )
}

fn fresh(name: String) -> #(String, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory must be readable"
  let root =
    here
    <> "/build/blobs-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _cleared = simplifile.delete(root)
  let legacy = root <> "/workspace/.blobs"
  let assert Ok(Nil) = simplifile.create_directory_all(legacy)
    as "the legacy directory must be creatable"
  #(legacy, root <> "/state/blobs")
}

fn write_bits(path: String, bytes: BitArray) -> Nil {
  let assert Ok(Nil) = simplifile.write_bits(path, bytes)
    as "the fixture file must be writable"
  Nil
}

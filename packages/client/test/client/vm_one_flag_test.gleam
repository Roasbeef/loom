//// The decisions behind `loom --vm`, held still: how a workspace names its
//// guest, which GitHub access a resume keeps, and what `ensure` does for each
//// combination of facts about the guest.
////
//// Every function under test is pure, so the tables and properties here need
//// no guest, no daemon and no file. The properties draw from fixed seeds, so a
//// red run is the same red run everywhere.

import client/vm_spec
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck

// The seed every property here draws from, and how many cases each checks.
const seed = 1113

const cases = 300

// --- setup for a missing or stale manifest ------------------------------------

const commit = "abc1234def5678abc1234def5678abc1234def56"

fn manifest_at(revision: String) -> vm_spec.Manifest {
  vm_spec.Manifest(
    revision:,
    loom_vm: "/h/loom-vm",
    runner: "/h/runner",
    lib_dir: "/h/lib",
    firmware_dir: None,
    guest_root: "/h/root",
  )
}

fn action(
  found: Option(vm_spec.Manifest),
  version: String,
) -> vm_spec.ManifestAction {
  vm_spec.manifest_action(found, version, commit, "/h/manifest.json")
}

pub fn a_release_build_installs_what_is_missing_or_stale_test() {
  let assert vm_spec.InstallRelease(missing) = action(None, "0.3.2")
  assert string.contains(missing, "No microVM artifacts are installed")
  assert string.contains(missing, "loom vm setup")

  // The words for a stale manifest name both revisions.
  let assert vm_spec.InstallRelease(stale) =
    action(Some(manifest_at("1111111")), "0.3.2")
  assert string.contains(stale, "1111111")
  assert string.contains(stale, commit)
  assert string.contains(stale, "loom vm setup")
}

pub fn a_release_build_uses_a_manifest_that_matches_test() {
  let current = manifest_at(commit)
  assert action(Some(current), "0.3.2") == vm_spec.UseManifest(current)

  // An abbreviation of seven characters or more is the same commit, and a
  // development tree's `dev` is accepted by every build.
  let short = manifest_at("abc1234")
  assert action(Some(short), "0.3.2") == vm_spec.UseManifest(short)
  let dev = manifest_at("dev")
  assert action(Some(dev), "0.3.2") == vm_spec.UseManifest(dev)
}

pub fn a_development_build_keeps_its_refusals_test() {
  let assert vm_spec.RefuseManifest(missing) = action(None, "dev")
  assert string.contains(missing, "make vmm-install-dev")

  let assert vm_spec.RefuseManifest(stale) =
    action(Some(manifest_at("1111111")), "dev")
  assert string.contains(stale, "make vmm-install-dev")
  assert vm_spec.manifest_action(
      Some(manifest_at("dev")),
      "dev",
      "unknown",
      "/h/manifest.json",
    )
    == vm_spec.UseManifest(manifest_at("dev"))
}

// --- the GitHub access a resume keeps -----------------------------------------

fn accesses() -> List(vm_spec.GitHubAccess) {
  [vm_spec.GitHubFromGh, vm_spec.GitHubFromEnv, vm_spec.GitHubOff]
}

pub fn github_record_round_trips_test() {
  assert list.all(accesses(), fn(access) {
    vm_spec.decode_github(vm_spec.encode_github(access)) == Ok(access)
  })
}

pub fn github_record_is_read_strictly_test() {
  assert vm_spec.decode_github("  off \n") == Ok(vm_spec.GitHubOff)
  assert result.is_error(vm_spec.decode_github(""))
  assert result.is_error(vm_spec.decode_github("on\n"))
  assert result.is_error(vm_spec.decode_github("gh\nenv\n"))
  assert result.is_error(vm_spec.decode_github("GH\n"))
}

// Every combination of given, recorded and freshness, as a table.
pub fn effective_github_table_test() {
  let none = None
  let off = Some(vm_spec.GitHubOff)
  let env = Some(vm_spec.GitHubFromEnv)

  // A flag given wins over the record, whatever the freshness.
  assert vm_spec.effective_github(env, off, vm_spec.Resume)
    == vm_spec.GitHubFromEnv
  assert vm_spec.effective_github(env, off, vm_spec.Fresh)
    == vm_spec.GitHubFromEnv

  // With no flag a resume keeps the record, and a guest with none gets gh.
  assert vm_spec.effective_github(none, off, vm_spec.Resume)
    == vm_spec.GitHubOff
  assert vm_spec.effective_github(none, none, vm_spec.Resume)
    == vm_spec.GitHubFromGh

  // `--fresh` forgets the record.
  assert vm_spec.effective_github(none, off, vm_spec.Fresh)
    == vm_spec.GitHubFromGh
}

// --- naming a guest after its workspace ---------------------------------------

// The six digits an independent computation of the digest gives, which the name
// must end with.
fn digest_tail(path: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(path))
  |> bit_array.base16_encode
  |> string.lowercase
  |> string.slice(0, 6)
}

pub fn guest_name_is_the_slug_and_the_digest_test() {
  let name = vm_spec.guest_name_for("/Users/me/src/Loom")
  assert name == "loom-" <> digest_tail("/Users/me/src/Loom")
}

pub fn guest_name_drops_what_a_name_cannot_hold_test() {
  // Characters outside the grammar are dropped, not replaced, and a name must
  // start with a letter.
  assert string.starts_with(
    vm_spec.guest_name_for("/src/My Proj.v2"),
    "myprojv2-",
  )
  assert string.starts_with(vm_spec.guest_name_for("/src/2fast"), "w2fast-")
  assert string.starts_with(vm_spec.guest_name_for("/src/_x"), "w_x-")
  assert string.starts_with(vm_spec.guest_name_for("/src/.."), "w-")
  assert string.starts_with(vm_spec.guest_name_for("/"), "w-")
  assert string.starts_with(vm_spec.guest_name_for(""), "w-")
}

pub fn guest_name_is_cut_to_the_limit_test() {
  let long = "/src/" <> string.repeat("a", 90)
  let name = vm_spec.guest_name_for(long)
  assert string.byte_size(name) == vm_spec.name_limit
  assert string.ends_with(name, "-" <> digest_tail(long))
}

pub fn guest_name_always_passes_valid_name_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(cases)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(qcheck.string(), fn(path) {
    let name = vm_spec.guest_name_for(path)
    assert vm_spec.valid_name(name) == Ok(Nil)
    assert name == vm_spec.guest_name_for(path)
    assert string.ends_with(name, "-" <> digest_tail(path))
  })
}

pub fn guests_of_same_named_directories_differ_test() {
  // Two directories under different parents with one last segment, which is
  // the case a bare slug would fold into one guest.
  qcheck.default_config()
  |> qcheck.with_test_count(cases)
  |> qcheck.with_seed(qcheck.seed(seed + 1))
  |> qcheck.run(
    qcheck.tuple3(qcheck.string(), qcheck.string(), qcheck.string()),
    fn(drawn) {
      let #(parent_a, parent_b, segment) = drawn
      let first = "/" <> parent_a <> "/" <> segment
      let second = "/" <> parent_b <> "/" <> segment

      // Only a pair whose digests differ in the digits kept can be told apart.
      case digest_tail(first) == digest_tail(second) {
        True -> Nil
        False -> {
          assert vm_spec.guest_name_for(first) != vm_spec.guest_name_for(second)
          Nil
        }
      }
    },
  )
}

pub fn guest_names_never_collide_with_the_authority_directory_test() {
  // The authority directory is a sibling of every guest, so a guest name must
  // never equal it; the digest suffix guarantees that.
  assert list.all(["/authority", "/src/authority", "/x"], fn(path) {
    vm_spec.guest_name_for(path) != vm_spec.authority_dir
  })
  assert result.is_ok(
    vm_spec.valid_name(vm_spec.guest_name_for("/src/authority")),
  )
}

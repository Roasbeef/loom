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
import gleam/result
import gleam/string
import qcheck

// The seed every property here draws from, and how many cases each checks.
const seed = 1113

const cases = 300

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

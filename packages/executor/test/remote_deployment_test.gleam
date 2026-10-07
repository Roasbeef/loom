//// Real canonical deployment placement and pure Describe derivation controls.

import broker/enrollment
import core/ids
import core/workspace
import executor/remote/deployment
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

fn fixture() -> #(String, String) {
  let suffix =
    crypto.strong_random_bytes(6) |> bit_array.base16_encode |> string.lowercase
  let root = "/private/tmp/ld-" <> suffix
  let directories = [
    root,
    root <> "/w",
    root <> "/b",
    root <> "/c",
    root <> "/t",
    root <> "/seed",
    root <> "/a",
    root <> "/s",
  ]
  list.each(directories, fn(path) {
    let assert Ok(Nil) = simplifile.create_directory(path)
      as "fixture directory"
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o700)
      as "private directory"
  })
  list.each(["ca", "cert", "key", "cookie", "options", "helper"], fn(name) {
    let path = root <> "/a/" <> name
    let assert Ok(Nil) = simplifile.write(path, "fixture\n")
      as "administrative file"
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o700)
      as "private executable"
  })
  list.each(["gleam", "erl"], fn(name) {
    let path = root <> "/t/" <> name
    let assert Ok(Nil) = simplifile.write(path, "fixture\n")
      as "toolchain executable"
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o700)
      as "executable file"
  })
  #(root, document(root))
}

fn document(root: String) -> String {
  "schema = 1
endpoint_lifetime = \"retired_slots_v1\"
owner = \"owner-a\"
local_node = \"exec@executor.example.invalid\"
[membership]
ca = \"@/a/ca\"
certificate = \"@/a/cert\"
key = \"@/a/key\"
cookie = \"@/a/cookie\"
options = \"@/a/options\"
[[peers]]
node = \"owner@owner.example.invalid\"
leaf_sha256 = \"1111111111111111111111111111111111111111111111111111111111111111\"
[executor]
helper = \"@/a/helper\"
pool_size = 2
state_root = \"@/s\"
[[workspaces]]
executor = \"exec-a\"
workspace = \"project-a\"
owner = \"owner-a\"
owner_peer = \"owner@owner.example.invalid\"
workspace_epoch = 1
session_epoch = 1
first_generation = 1
generation_policy = \"clean_successor\"
descriptor_sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\"
compilation_contract_sha256 = \"3333333333333333333333333333333333333333333333333333333333333333\"
native_demand = \"full\"
native_working_roots = [\"@\"]
native_ceiling = '{\"v\":2,\"writable_roots\":[\"@/w\",\"@/b\",\"@/c\"],\"readable_roots\":[\"@/seed\",\"@/t\"],\"protected\":[\"@/a/ca\",\"@/a/cert\",\"@/a/key\",\"@/a/cookie\",\"@/a/options\",\"@/a/helper\",\"@/s\"],\"network\":{\"mode\":\"off\"},\"limits\":{\"cpu_s\":10,\"wall_s\":60,\"mem_bytes\":100000000,\"pids\":32,\"fsize_bytes\":10000000,\"output_bytes\":262144},\"env_allow\":[\"PATH\"],\"scratch\":\"tmpfs\",\"mounts\":[]}'
[workspaces.code_mode]
workspace_root = \"@/w\"
build_area = \"@/b\"
channel_area = \"@/c\"
gleam_path = \"@/t/gleam\"
erl_path = \"@/t/erl\"
seed_root = \"@/seed\"
toolchain_roots = [\"@/t\"]
build_path = \"@/t\"
host_mounts = []
[workspaces.lsp]
"
  |> string.replace("@/", root <> "/")
  |> string.replace("[\"@\"]", "[\"" <> root <> "\"]")
}

fn seal(text: String) -> #(workspace.RegisteredBinding, String, String) {
  let assert Ok([#(binding, digest)]) = deployment.fingerprints(text)
    as "canonical provisioning commitment"
  #(binding, digest, string.replace(text, string.repeat("0", 64), digest))
}

fn load_document(
  root: String,
  text: String,
) -> Result(deployment.Table, deployment.DeploymentError) {
  let path = root <> "/deployment.toml"
  let assert Ok(Nil) = simplifile.write(path, text) as "deployment source"
  deployment.load(path)
}

fn session(last: String) -> ids.SessionId {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-00000000000" <> last)
    as "session identity"
  session
}

pub fn actual_placement_and_pure_session_derived_registration_test() {
  let #(root, text) = fixture()
  let #(binding, digest, text) = seal(text)
  let assert Ok(table) = load_document(root, text)
    as "actual canonical placement"
  let assert Ok(descriptor) = deployment.select(table, binding, digest)
    as "exact descriptor"
  let assert Ok(first) = deployment.describe(descriptor, session("2"))
    as "first session"
  let assert Ok(second) = deployment.describe(descriptor, session("3"))
    as "second session"
  assert enrollment.native_facts(first).scope
    == workspace.scope(session("2"), binding)
  assert enrollment.native_facts(second).scope
    == workspace.scope(session("3"), binding)
  assert enrollment.digests(first).0 != enrollment.digests(second).0
  assert enrollment.digests(first).1 == enrollment.digests(second).1
  let assert Ok(first_bytes) = enrollment.encode(first)
    as "canonical first enrollment"
  assert enrollment.decode(first_bytes) == Ok(first)
  assert deployment.descriptor_fields(descriptor)
    == #(binding, "owner-a", "owner@owner.example.invalid", digest, 1)
  assert deployment.settings(table).pool_size == 2

  // Describe remains pure after physical facts disappear or administrative text changes.
  let assert Ok(Nil) = simplifile.delete(root <> "/t/gleam")
    as "remove original executable"
  assert deployment.describe(descriptor, session("2")) == Ok(first)
  assert deployment.select(table, binding, string.repeat("4", 64))
    == Error(deployment.Unavailable)
  assert load_document(root, text) == Error(deployment.InvalidPlacement)
  let assert Ok(Nil) = simplifile.delete(root) as "fixture cleanup"
}

pub fn protected_placement_and_aliases_refuse_test() {
  let #(root, text) = fixture()
  let #(binding, digest, text) = seal(text)
  let assert Ok(table) = load_document(root, text) as "baseline"
  assert deployment.select(table, binding, digest) |> result.is_ok
  let raw = document(root)
  let overlapping =
    string.replace(
      raw,
      "\"writable_roots\":[\"" <> root <> "/w\",",
      "\"writable_roots\":[\"" <> root <> "/a\",\"" <> root <> "/w\",",
    )
  let #(_, _, overlapping) = seal(overlapping)
  assert load_document(root, overlapping) == Error(deployment.ProtectedOverlap)
  let exposed =
    string.replace(
      raw,
      "\"readable_roots\":[",
      "\"readable_roots\":[\"" <> root <> "/a\",",
    )
  let #(_, _, exposed) = seal(exposed)
  assert load_document(root, exposed) == Error(deployment.ProtectedOverlap)
  let assert Ok(Nil) = simplifile.create_symlink(root <> "/w", root <> "/alias")
    as "alias"
  let aliased = string.replace(raw, root <> "/w", root <> "/alias")
  let #(_, _, aliased) = seal(aliased)
  assert load_document(root, aliased) == Error(deployment.InvalidPlacement)
  let assert Ok(Nil) = simplifile.delete(root) as "fixture cleanup"
}

pub fn strict_shapes_policy_keys_and_raw_bounds_test() {
  let #(root, text) = fixture()
  let variants = [
    "unknown = 1\n" <> text,
    "schema = 1\n" <> text,
    string.replace(text, "pool_size = 2", "pool_size = 0"),
    string.replace(text, "pool_size = 2", "pool_size = 33"),
    string.replace(
      text,
      "owner_peer = \"owner@owner.example.invalid\"",
      "owner_peer = \"other@host\"",
    ),
    string.replace(
      text,
      "native_demand = \"full\"",
      "native_demand = \"best_effort\"",
    ),
    string.replace(text, "\"v\":2", "\"v\":2,\"unexpected\":0"),
    string.replace(text, "\"v\":2", "\"v\":2,\"v\":2"),
    string.replace(text, "first_generation = 1", "first_generation = 0"),
    string.replace(
      text,
      "host_mounts = []",
      "host_mounts = [{path=\"/tool\",access=\"read-write\",presence=\"required\"}]",
    ),
    string.replace(
      text,
      "host_mounts = []",
      "host_mounts = [{path=\"/tool\",access=\"read-only\",presence=\"optional\"}]",
    ),
  ]
  list.each(variants, fn(text) {
    assert deployment.fingerprints(text)
      == Error(deployment.InvalidConfiguration)
  })
  assert deployment.fingerprints(string.repeat("x", 8_388_609))
    == Error(deployment.TooLarge)
  assert load_document(root, text) == Error(deployment.DescriptorMismatch)
  let assert Ok(Nil) = simplifile.set_permissions_octal(root <> "/s", 0o755)
    as "public state dir"
  let #(_, _, sealed) = seal(text)
  assert load_document(root, sealed) == Error(deployment.InvalidPlacement)
  let assert Ok(Nil) = simplifile.delete(root) as "fixture cleanup"
}

fn profiles(root: String, count: Int) -> String {
  int.range(0, count, with: [], run: fn(acc, ordinal) { [ordinal, ..acc] })
  |> list.map(fn(index) {
    let suffix = int.to_string(index)
    "[workspaces.lsp.lang"
    <> suffix
    <> "]\ncommand=[\""
    <> root
    <> "/t/gleam\",\"lsp\"]\nextensions=[\".ext"
    <> suffix
    <> "\"]\nroot_markers=[\"gleam.toml\"]\nproject=\"read-only\"\nreadable=[]\nwritable=[]\nenv=[]\n"
  })
  |> string.join("")
}

pub fn all_sixteen_profiles_preserved_in_frozen_sorted_order_test() {
  let #(root, text) = fixture()
  let #(binding, digest, sealed) = seal(text <> profiles(root, 16))
  let assert Ok(table) = load_document(root, sealed)
    as "sixteen installed profiles"
  let assert Ok(descriptor) = deployment.select(table, binding, digest)
    as "selected"
  let names =
    list.map(deployment.lsp_profiles(descriptor), fn(profile) { profile.name })
  assert list.length(names) == 16
  assert names == list.sort(names, string.compare)
  assert deployment.fingerprints(text <> profiles(root, 17))
    == Error(deployment.InvalidConfiguration)
  let assert Ok(Nil) = simplifile.delete(root) as "fixture cleanup"
}

pub fn working_root_descriptor_count_and_generation_bound_test() {
  let #(root, text) = fixture()
  let #(_, _, text) =
    seal(string.replace(
      text,
      "first_generation = 1",
      "first_generation = 2147483647",
    ))
  let assert Ok(table) = load_document(root, text)
    as "full positive generation range"
  let assert Ok([#(binding, digest)]) = deployment.fingerprints(text)
    as "binding and digest"
  let assert Ok(descriptor) = deployment.select(table, binding, digest)
    as "descriptor"
  assert deployment.descriptor_fields(descriptor).4 == 2_147_483_647
  assert deployment.fingerprints(string.replace(
      text,
      "first_generation = 2147483647",
      "first_generation = 2147483648",
    ))
    == Error(deployment.InvalidConfiguration)
  let roots = list.repeat("\"" <> root <> "\"", 17) |> string.join(",")
  let many_roots =
    string.replace(
      document(root),
      "native_working_roots = [\"" <> root <> "\"]",
      "native_working_roots = [" <> roots <> "]",
    )
  assert deployment.fingerprints(many_roots)
    == Error(deployment.InvalidConfiguration)
  let assert [header, row] = string.split(document(root), "[[workspaces]]")
    as "single descriptor fixture"
  let descriptors =
    int.range(0, 33, with: [], run: fn(acc, index) {
      [
        "[[workspaces]]"
          <> string.replace(
          row,
          "project-a",
          "project-" <> int.to_string(index),
        ),
        ..acc
      ]
    })
  assert deployment.fingerprints(
      header <> string.join(list.take(descriptors, 32), ""),
    )
    |> result.is_ok
  assert deployment.fingerprints(header <> string.join(descriptors, ""))
    == Error(deployment.InvalidConfiguration)
  let assert Ok(Nil) = simplifile.delete(root) as "fixture cleanup"
}

pub fn shared_readonly_bin_is_legal_and_helper_write_paths_refuse_test() {
  let #(root, text) = fixture()
  let shared =
    text
    |> string.replace(
      "helper = \"" <> root <> "/a/helper\"",
      "helper = \"" <> root <> "/t/gleam\"",
    )
    |> string.replace(
      "\"mounts\":[]",
      "\"mounts\":[{\"path\":\""
        <> root
        <> "/t\",\"access\":\"ro\",\"required\":true}]",
    )
    |> string.replace(
      "host_mounts = []",
      "host_mounts = [{path=\""
        <> root
        <> "/t\",access=\"read-only\",presence=\"required\"}]",
    )
  let #(_, _, shared) = seal(shared)
  assert load_document(root, shared) |> result.is_ok
  let helper_root = root <> "/h"
  let assert Ok(Nil) = simplifile.create_directory(helper_root)
    as "separate immutable helper root"
  let assert Ok(Nil) = simplifile.write(helper_root <> "/helper", "fixture")
    as "host helper"
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(helper_root <> "/helper", 0o700)
    as "executable"
  let separate =
    string.replace(
      document(root),
      "helper = \"" <> root <> "/a/helper\"",
      "helper = \"" <> helper_root <> "/helper\"",
    )
  let #(_, _, separate) = seal(separate)
  assert load_document(root, separate) |> result.is_ok
  let scratch =
    string.replace(
      separate,
      "\"scratch\":\"tmpfs\"",
      "\"scratch\":\"" <> helper_root <> "\"",
    )
  let #(_, _, scratch) = seal(scratch)
  assert load_document(root, scratch) == Error(deployment.ProtectedOverlap)
  let mount =
    string.replace(
      separate,
      "\"mounts\":[]",
      "\"mounts\":[{\"path\":\""
        <> helper_root
        <> "\",\"access\":\"rw\",\"required\":true}]",
    )
  let #(_, _, mount) = seal(mount)
  assert load_document(root, mount) == Error(deployment.ProtectedOverlap)
  let writable =
    string.replace(
      separate,
      "\"writable_roots\":[",
      "\"writable_roots\":[\"" <> helper_root <> "\",",
    )
  let #(_, _, writable) = seal(writable)
  assert load_document(root, writable) == Error(deployment.ProtectedOverlap)
  let assert Ok(Nil) = simplifile.delete(root) as "fixture cleanup"
}

pub fn changed_executor_endpoint_changes_commitment_and_refuses_old_digest_test() {
  let #(root, original) = fixture()
  let #(binding, original_digest, sealed) = seal(original)
  let changed =
    string.replace(
      original,
      "exec@executor.example.invalid",
      "otherexec@executor.example.invalid",
    )
  let #(same_binding, changed_digest, changed_sealed) = seal(changed)
  assert same_binding == binding
  assert changed_digest != original_digest

  // Identical physical facts cannot preserve the original endpoint's expected commitment.
  let old_expected =
    string.replace(
      sealed,
      "exec@executor.example.invalid",
      "otherexec@executor.example.invalid",
    )
  assert load_document(root, old_expected)
    == Error(deployment.DescriptorMismatch)
  let assert Ok(table) = load_document(root, changed_sealed)
    as "new endpoint with its own commitment"
  assert deployment.select(table, binding, original_digest)
    == Error(deployment.Unavailable)
  let assert Ok(_) = deployment.select(table, binding, changed_digest)
    as "fresh commitment selects new endpoint"
  let assert Ok(Nil) = simplifile.delete(root) as "fixture cleanup"
}

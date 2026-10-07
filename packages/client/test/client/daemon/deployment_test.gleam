//// Exact administrative authority and companion enrollment verification.

import broker/enrollment
import broker/exec
import broker/policy
import client/daemon/deployment
import core/generation
import core/ids
import core/workspace
import executor/remote/identity
import executor/remote/registration
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import storage/owner_custody

fn document() -> String {
  "schema = 1
endpoint_lifetime = \"retired_slots_v1\"
owner = \"owner-a\"
local_node = \"owner@owner.example.invalid\"
[membership]
ca = \"/etc/loom-owner/ca.pem\"
certificate = \"/etc/loom-owner/cert.pem\"
key = \"/etc/loom-owner/key.pem\"
cookie = \"/etc/loom-owner/.erlang.cookie\"
options = \"/etc/loom-owner/tls.options\"
[[peers]]
node = \"exec@executor.example.invalid\"
leaf_sha256 = \"1111111111111111111111111111111111111111111111111111111111111111\"
" <> row()
}

fn row() -> String {
  "[[workspaces]]
executor = \"exec-a\"
workspace = \"project-a\"
peer = \"exec@executor.example.invalid\"
workspace_epoch = 1
session_epoch = 1
first_generation = 1
generation_policy = \"clean_successor\"
descriptor_sha256 = \"2222222222222222222222222222222222222222222222222222222222222222\"
"
}

fn binding(epoch: Int) -> workspace.RegisteredBinding {
  let assert Ok(selector) = workspace.selector("exec-a", "project-a")
    as "selector"
  let assert Ok(binding) = workspace.registered_binding(selector, epoch, 1)
    as "binding"
  binding
}

pub fn exact_protocol077_example_and_same_table_authority_test() {
  let assert Ok(table) = deployment.decode(document())
    as "exact approved example"
  let assert Ok(selected) = deployment.select(table, binding(1))
    as "configured binding"
  let #(retained, peer, digest, first) = deployment.selected_fields(selected)
  assert retained == binding(1)
  assert peer == "exec@executor.example.invalid"
  assert string.byte_size(digest) == 64
  assert first == 1
  assert deployment.owner(table) == "owner-a"
  let authority = deployment.authority(table)
  let #(selector, _, _) = workspace.binding_fields(retained)
  assert authority.resolve(workspace.RegisteredWorkspace(selector))
    == Ok(workspace.Registered(retained))
  assert authority.revalidate(workspace.Registered(binding(2)))
    == Error("workspace_unavailable")
  assert deployment.select(table, binding(2)) == Error(deployment.Unavailable)
}

pub fn strict_keys_types_duplicates_and_identity_test() {
  let original = document()
  let variants = [
    "unknown = 1\n" <> original,
    "schema = 1\n" <> original,
    string.replace(original, "workspace_epoch = 1", "workspace_epoch = 0"),
    string.replace(original, "session_epoch = 1", "session_epoch = 2147483648"),
    string.replace(original, "first_generation = 1", "first_generation = 0"),
    string.replace(original, "owner-a", "../owner"),
    string.replace(original, "project-a", "../project"),
    string.replace(original, "retired_slots_v1", "legacy"),
    string.replace(original, "clean_successor", "automatic_failover"),
    string.replace(original, "workspace_epoch = 1", "workspace_epoch = \"1\""),
    string.replace(original, "tls.options", "tls.options\"\nextra = \"x"),
    original <> row(),
    string.replace(
      original,
      "peer = \"exec@executor.example.invalid\"",
      "peer = \"other@host\"",
    ),
    string.replace(
      original,
      "2222222222222222222222222222222222222222222222222222222222222222",
      "ABCDEF",
    ),
  ]
  list.each(variants, fn(text) {
    assert deployment.decode(text) == Error(deployment.InvalidConfiguration)
  })
}

pub fn preparse_bound_and_full_positive_first_generation_test() {
  assert deployment.decode(string.repeat("x", 8_388_609))
    == Error(deployment.TooLarge)
  let assert Ok(table) =
    deployment.decode(string.replace(
      document(),
      "first_generation = 1",
      "first_generation = 2147483647",
    ))
    as "full generation bound"
  let assert Ok(selected) = deployment.select(table, binding(1)) as "binding"
  assert deployment.selected_fields(selected).3 == 2_147_483_647
}

pub fn workspace_and_peer_count_bounds_test() {
  let variants =
    int.range(1, 34, with: [], run: fn(acc, value) { [value, ..acc] })
    |> list.map(fn(index) {
      row() |> string.replace("project-a", "project-" <> string.inspect(index))
    })
  let header =
    string.split(document(), "[[workspaces]]")
    |> list.first
    |> result.unwrap("")
  assert deployment.decode(header <> string.join(variants, ""))
    == Error(deployment.InvalidConfiguration)
  assert deployment.decode(header) == Error(deployment.InvalidConfiguration)
  let peer =
    "[[peers]]\nnode = \"other@host.invalid\"\nleaf_sha256 = \"1111111111111111111111111111111111111111111111111111111111111111\"\n"
  assert deployment.decode(header <> peer <> row())
    == Error(deployment.InvalidConfiguration)
}

fn pin_bytes() -> #(ids.SessionId, BitArray) {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "session"
  let roots = ["/work", "/build", "/channel"]
  let base = policy.workspace_default("/work")
  let ceiling =
    policy.SandboxPolicy(
      ..base,
      writable_roots: roots,
      readable_roots: ["/tools", "/seed"],
      protected: [],
      mounts: [],
    )
  let native =
    enrollment.NativeFacts(
      workspace.scope(session, binding(1)),
      roots,
      ceiling,
      exec.FullEnforcement,
    )
  let code =
    enrollment.CodeModeFacts(
      "/work",
      "/build",
      "/channel",
      "/tools/gleam",
      "/tools/erl",
      "/seed",
      ["/tools"],
      [],
      "/tools",
    )
  let assert Ok(executor_id) = identity.executor_id("exec-a") as "executor"
  let assert Ok(workspace_id) = identity.workspace_id("project-a")
    as "workspace"
  let assert Ok(epoch) = identity.epoch(1) as "epoch"
  let scope = identity.scope(session, workspace_id, executor_id, epoch, epoch)
  let assert Ok(registered) =
    registration.new(scope, roots, ceiling, exec.FullEnforcement, Ok)
    as "registration"
  let registration_digest =
    identity.digest_bytes(registration.digest(registered))
    |> bit_array.base16_encode
    |> string.lowercase
  let assert Ok(enrolled) =
    enrollment.new(native, code, registration_digest, string.repeat("4", 64))
    as "valid immutable enrollment"
  let assert Ok(bytes) = enrollment.encode(enrolled) as "canonical enrollment"
  #(session, bytes)
}

fn stored(
  session: ids.SessionId,
  bytes: BitArray,
) -> owner_custody.EnrollmentPin {
  let assert Ok(descriptor_bytes) =
    bit_array.base16_decode(string.repeat("2", 64))
    as "digest spelling"
  let assert Ok(descriptor) = generation.digest(descriptor_bytes)
    as "exact configured digest"
  let assert Ok(digest) = generation.digest(bootstrap.sha256(bytes))
    as "body hash"
  let assert Ok(pin) =
    owner_custody.enrollment_pin(session, binding(1), descriptor, digest, bytes)
    as "bounded metadata"
  pin
}

pub fn companion_pin_checks_canonical_body_hash_scope_and_descriptor_test() {
  let assert Ok(table) = deployment.decode(document()) as "table"
  let assert Ok(selected) = deployment.select(table, binding(1)) as "selected"
  let #(session, bytes) = pin_bytes()
  let original = stored(session, bytes)
  let assert Ok(pin) = deployment.pinned(selected, original) as "verified pin"
  assert deployment.revalidate(table, pin) == Ok(Nil)
  assert deployment.pin_fields(pin).0 == original
  let assert Ok(other) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000002")
    as "other session"
  assert deployment.pinned(selected, stored(other, bytes))
    == Error(deployment.PinMismatch)
  assert deployment.pinned(selected, stored(session, <<bytes:bits, 0>>))
    == Error(deployment.PinMismatch)
  let assert Ok(changed) =
    deployment.decode(string.replace(
      document(),
      string.repeat("2", 64),
      string.repeat("5", 64),
    ))
    as "changed descriptor"
  assert deployment.revalidate(changed, pin) == Error(deployment.PinMismatch)
}

pub fn reopened_endpoint_or_commitment_refuses_original_companion_pin_test() {
  let assert Ok(table) = deployment.decode(document()) as "original table"
  let assert Ok(selected) = deployment.select(table, binding(1))
    as "original selected route"
  let #(session, bytes) = pin_bytes()
  let original = stored(session, bytes)
  let assert Ok(pin) = deployment.pinned(selected, original)
    as "original companion pin"
  let rerouted =
    string.replace(
      document(),
      "exec@executor.example.invalid",
      "otherexec@executor.example.invalid",
    )
  let assert Ok(table) = deployment.decode(rerouted) as "reopened route"
  assert deployment.revalidate(table, pin) == Error(deployment.PinMismatch)

  // A newly committed descriptor cannot adopt the old endpoint's companion pin.
  let recommitted =
    string.replace(rerouted, string.repeat("2", 64), string.repeat("5", 64))
  let assert Ok(table) = deployment.decode(recommitted) as "new commitment"
  let assert Ok(selected) = deployment.select(table, binding(1))
    as "new selected route"
  assert deployment.pinned(selected, original) == Error(deployment.PinMismatch)
  assert deployment.revalidate(table, pin) == Error(deployment.PinMismatch)
}

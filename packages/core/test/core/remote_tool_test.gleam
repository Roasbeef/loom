//// Pure identity checks pin byte bounds and disjoint durable child origins.

import core/clock
import core/ids
import core/json
import core/remote_tool
import gleam/list
import gleam/result
import gleam/string

fn make_key(step: String, index: Int, digest: String) {
  let generator = ids.generator(clock.fixed(1000), 27)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(result, _) = ids.mint_entry(generator)
  remote_tool.key(session, operation, step, index, digest, result)
}

pub fn bounded_identity_refuses_untrusted_names_indices_and_digests_test() {
  let digest = string.repeat("a", 64)
  assert make_key("", 0, digest) != make_key("step", 0, digest)
  let assert Error(_) = make_key(string.repeat("é", 513), 0, digest)
    as "step bound is UTF-8 bytes rather than graphemes"
  let assert Ok(_) = make_key(string.repeat("é", 512), 0, digest)
    as "parent steps share the workspace 1024-byte bound"
  let assert Error(_) = make_key("step\u{0000}", 0, digest)
    as "NUL is refused at the identity boundary"
  let assert Error(_) = make_key("step", -1, digest)
    as "negative indices are refused"
  let assert Error(_) = make_key("step", 4096, digest)
    as "oversized indices are refused"
  let assert Error(_) = make_key("step", 0, string.repeat("A", 64))
    as "digest spelling is canonical lowercase"
  let assert Error(_) = make_key("step", 0, string.repeat("z", 64))
    as "a same-width non-hex digest is refused"
}

pub fn changed_digest_reaches_original_logical_fence_test() {
  let assert Ok(a) = make_key("step:with:separators", 2, string.repeat("a", 64))
    as "first complete identity validates"
  let assert Ok(b) = make_key("step:with:separators", 2, string.repeat("b", 64))
    as "another digest validates independently"
  assert remote_tool.address(a) == remote_tool.address(b)
  assert remote_tool.encode(a) != remote_tool.encode(b)
}

pub fn explicit_child_origins_cannot_alias_test() {
  let assert Ok(key) = make_key("step", 0, string.repeat("a", 64))
    as "complete tool identity validates"
  let assert Ok(compile) = remote_tool.tool_child(key, remote_tool.Compile)
    as "compile origin validates"
  let assert Ok(launch) = remote_tool.tool_child(key, remote_tool.Launch)
    as "launch origin validates"
  let assert Ok(cap) = remote_tool.tool_child(key, remote_tool.Capability(0))
    as "capability origin validates"
  let assert Ok(system) =
    remote_tool.system_child(remote_tool.session(key), "step", 0)
    as "system origin validates without a fake operation"
  assert remote_tool.child_address(compile) != remote_tool.child_address(launch)
  assert remote_tool.child_address(launch) != remote_tool.child_address(cap)
  assert remote_tool.child_address(cap) != remote_tool.child_address(system)
  assert remote_tool.child_tool(system) == Error(Nil)
  let assert Error(_) = remote_tool.tool_child(key, remote_tool.Capability(-1))
    as "capability ordinals are bounded at construction"
  let assert Error(_) =
    remote_tool.system_child(remote_tool.session(key), "lsp", 4096)
    as "system ordinals are bounded too"
}

pub fn workspace_child_is_disjoint_and_ordinals_are_bounded_test() {
  let assert Ok(key) = make_key("step", 3, string.repeat("a", 64))
    as "Complete tool provenance validates."
  let assert Ok(workspace) =
    remote_tool.tool_child(key, remote_tool.Workspace(0))
    as "Semantic workspace has its own durable namespace."
  let assert Ok(compile) = remote_tool.tool_child(key, remote_tool.Compile)
    as "Physical compile retains its namespace."
  let assert Ok(launch) = remote_tool.tool_child(key, remote_tool.Launch)
    as "Physical launch retains its namespace."
  let assert Ok(capability) =
    remote_tool.tool_child(key, remote_tool.Capability(0))
    as "Capability ordinal does not alias workspace ordinal."
  assert remote_tool.child_address(workspace)
    != remote_tool.child_address(compile)
  assert remote_tool.child_address(workspace)
    != remote_tool.child_address(launch)
  assert remote_tool.child_address(workspace)
    != remote_tool.child_address(capability)
  assert remote_tool.child_role(workspace) == Ok(remote_tool.Workspace(0))
  assert remote_tool.provenance(key) == #(3, string.repeat("a", 64))
  assert remote_tool.tool_child(key, remote_tool.Workspace(-1))
    |> result.is_error
  assert remote_tool.tool_child(key, remote_tool.Workspace(4096))
    |> result.is_error
}

/// The same per-capability ordinal names different effects and retained rows.
pub fn admitted_capability_tuples_and_command_roles_do_not_alias_test() {
  let assert Ok(key) = make_key("step", 0, string.repeat("a", 64))
    as "The original tool key validates."
  let roles = [
    remote_tool.Compile,
    remote_tool.Launch,
    remote_tool.CompileCommand,
    remote_tool.SatelliteCommand,
    remote_tool.Capability(0),
    remote_tool.Workspace(0),
    remote_tool.AdmittedCapability("fs.read", 0, remote_tool.SemanticWorkspace),
    remote_tool.AdmittedCapability("proc.run", 0, remote_tool.SemanticWorkspace),
    remote_tool.AdmittedCapability("fs.read", 0, remote_tool.NativeCommand),
    remote_tool.AdmittedCapability("proc.run", 0, remote_tool.NativeCommand),
  ]
  let addresses =
    list.map(roles, fn(role) {
      let assert Ok(child) = remote_tool.tool_child(key, role)
        as "Each admitted logical role validates."
      assert remote_tool.child_tool(child) == Ok(key)
      remote_tool.child_address(child)
    })
  assert list.length(list.unique(addresses)) == list.length(roles)
}

/// New role tags must not change the keys of already retained legacy evidence.
pub fn legacy_child_addresses_remain_byte_exact_test() {
  let assert Ok(key) = make_key("step", 0, string.repeat("a", 64))
    as "The original tool key validates."
  let legacy = [
    #(remote_tool.Compile, json.Array([json.String("compile")])),
    #(remote_tool.Launch, json.Array([json.String("launch")])),
    #(remote_tool.Capability(0), json.Array([json.String("cap"), json.Int(0)])),
    #(
      remote_tool.Workspace(0),
      json.Array([json.String("workspace"), json.Int(0)]),
    ),
  ]
  list.each(legacy, fn(entry) {
    let assert Ok(child) = remote_tool.tool_child(key, entry.0)
      as "The legacy role remains constructible."
    let expected =
      json.to_string(
        json.Array([
          json.String(remote_tool.address(key)),
          entry.1,
        ]),
      )
    assert remote_tool.child_address(child) == expected
  })
}

/// Names have an independent byte bound and retain exact tuple encoding.
pub fn capability_names_are_bounded_without_delimiter_aliases_test() {
  let assert Ok(key) = make_key("step", 0, string.repeat("a", 64))
    as "The original tool key validates."
  list.each(["", "fs\u{0000}read", string.repeat("é", 65)], fn(name) {
    assert remote_tool.tool_child(
        key,
        remote_tool.AdmittedCapability(name, 0, remote_tool.SemanticWorkspace),
      )
      |> result.is_error
  })
  list.each([-1, 4096], fn(ordinal) {
    assert remote_tool.tool_child(
        key,
        remote_tool.AdmittedCapability(
          "fs.read",
          ordinal,
          remote_tool.SemanticWorkspace,
        ),
      )
      |> result.is_error
  })

  let assert Ok(maximum) =
    remote_tool.tool_child(
      key,
      remote_tool.AdmittedCapability(
        string.repeat("é", 64),
        4095,
        remote_tool.NativeCommand,
      ),
    )
    as "The exact name and ordinal bounds are accepted."
  assert remote_tool.child_tool(maximum) == Ok(key)
  let names = ["fs.read", "fs.read:0:workspace", "fs.read\",0,\"workspace"]
  let addresses =
    list.map(names, fn(name) {
      let assert Ok(child) =
        remote_tool.tool_child(
          key,
          remote_tool.AdmittedCapability(name, 0, remote_tool.SemanticWorkspace),
        )
        as "Separators remain literal name data in the canonical tuple."
      remote_tool.child_address(child)
    })
  assert list.length(list.unique(addresses)) == list.length(names)
}

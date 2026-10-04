//// Pure identity checks pin byte bounds and disjoint durable child origins.

import core/clock
import core/ids
import core/remote_tool
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

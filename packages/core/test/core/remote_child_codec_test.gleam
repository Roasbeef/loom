//// Complete child codecs preserve original provenance and refuse malformed shapes.

import core/clock
import core/ids
import core/msgpack as m
import core/remote_tool as r
import gleam/list
import gleam/result
import gleam/string

fn key() {
  let generator = ids.generator(clock.fixed(1000), 42)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(entry, _) = ids.mint_entry(generator)
  let assert Ok(parent) =
    r.key(session, operation, "step", 4095, string.repeat("a", 64), entry)
    as "The complete original parent is valid."
  parent
}

pub fn every_closed_child_role_roundtrips_complete_original_fields_test() {
  let parent = key()
  let roles = [
    r.Compile,
    r.CompileRewrite,
    r.Launch,
    r.CompileCommand,
    r.CompileRewriteCommand,
    r.SatelliteCommand,
    r.Capability(4095),
    r.Workspace(4095),
    r.AdmittedCapability("lsp.rename", 4095, r.SemanticWorkspace),
    r.AdmittedCapability("lsp.rename", 4095, r.NativeCommand),
  ]
  list.each(roles, fn(role) {
    let assert Ok(child) = r.tool_child(parent, role)
      as "Each declared role validates."
    let assert Ok(encoded) = r.encode_child(child)
      as "The bounded original encodes."
    assert r.decode_child(encoded) == Ok(child)
    assert r.decode_child_value(r.child_value(child)) == Ok(child)
    assert r.child_fields(child) == r.ToolFields(parent, role)
  })
  let assert Ok(system) =
    r.system_child(r.session(parent), string.repeat("é", 64), 4095)
    as "The exact UTF-8 service boundary validates."
  let assert Ok(encoded) = r.encode_child(system)
    as "The system origin encodes."
  assert r.decode_child(encoded) == Ok(system)
  assert r.child_fields(system)
    == r.SystemFields(r.session(parent), string.repeat("é", 64), 4095)
}

pub fn system_shape_is_pinned_and_surplus_coordinates_refuse_test() {
  let parent = key()
  let session = ids.session_id_to_string(r.session(parent))
  let value =
    m.ArrayValue([
      m.IntValue(1),
      m.IntValue(1),
      m.StringValue(session),
      m.StringValue("lsp"),
      m.IntValue(0),
    ])
  let assert Ok(system) = r.system_child(r.session(parent), "lsp", 0)
    as "The system origin validates."
  assert r.child_value(system) == value
  list.each([-1, 4096], fn(ordinal) {
    assert r.decode_child_value(
        m.ArrayValue([
          m.IntValue(1),
          m.IntValue(1),
          m.StringValue(session),
          m.StringValue("lsp"),
          m.IntValue(ordinal),
        ]),
      )
      |> result.is_error
  })
  list.each(["", string.repeat("é", 65), "lsp\u{0000}"], fn(service) {
    assert r.decode_child_value(
        m.ArrayValue([
          m.IntValue(1),
          m.IntValue(1),
          m.StringValue(session),
          m.StringValue(service),
          m.IntValue(0),
        ]),
      )
      |> result.is_error
  })
  assert r.decode_child_value(
      m.ArrayValue([
        m.IntValue(1),
        m.IntValue(1),
        m.StringValue(session),
        m.StringValue("lsp"),
        m.IntValue(0),
        m.NilValue,
      ]),
    )
    |> result.is_error
}

pub fn malformed_and_noncanonical_raw_identity_cannot_bypass_preflight_test() {
  let parent = key()
  let assert Ok(system) = r.system_child(r.session(parent), "lsp", 0)
    as "The system origin validates."
  let assert Ok(bytes) = r.encode_child(system) as "The system origin encodes."
  let assert <<0x95, 1, rest:bits>> = bytes
    as "The version uses its shortest encoding."
  assert r.decode_child(<<0x95, 0xcc, 1, rest:bits>>) |> result.is_error
  assert r.decode_child(<<bytes:bits, 0>>) |> result.is_error
  assert r.decode_child(<<0xdd, 200_001:32>>) |> result.is_error
  assert r.decode_child(<<0xdb, 8193:32>>) |> result.is_error
  assert r.decode_child(<<1:size(1)>>) |> result.is_error
}

pub fn full_tool_parent_digest_and_result_id_remain_conflict_evidence_test() {
  let parent = key()
  let assert Ok(first) =
    r.tool_child(
      parent,
      r.AdmittedCapability("lsp.hover", 0, r.SemanticWorkspace),
    )
    as "The admitted semantic child validates."
  let assert Ok(changed) =
    r.key(
      r.session(parent),
      r.operation(parent),
      r.step(parent),
      r.source_index(parent),
      string.repeat("b", 64),
      r.result_entry(parent),
    )
    as "Another original digest is syntactically valid."
  let assert Ok(second) =
    r.tool_child(
      changed,
      r.AdmittedCapability("lsp.hover", 0, r.SemanticWorkspace),
    )
    as "The changed child reaches the same logical address."
  assert r.child_address(first) == r.child_address(second)
  assert r.child_value(first) != r.child_value(second)
  let assert Ok(encoded) = r.encode_child(second)
    as "The changed identity encodes."
  assert r.decode_child(encoded) == Ok(second)
}

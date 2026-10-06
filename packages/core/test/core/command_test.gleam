//// Pure service identity controls separate deterministic addresses from content.

import core/clock
import core/command
import core/ids
import core/json
import core/remote_tool
import core/workspace
import gleam/list
import gleam/option
import gleam/result
import gleam/string

fn parent() -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(1000), 77)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(entry, _) = ids.mint_entry(generator)
  let assert Ok(key) =
    remote_tool.key(
      session,
      operation,
      "parent",
      3,
      string.repeat("a", 64),
      entry,
    )
    as "Complete runtime provenance validates."
  key
}

fn make_service(
  role: command.ServiceRole,
  input: String,
) -> command.ServiceKey {
  let parent = parent()
  let assert Ok(scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(remote_tool.session(parent)),
      "repo",
      "executor",
      2,
      3,
    )
    as "The registered scope retains both epochs."
  let assert Ok(step) = workspace.step("physical:build")
    as "The physical step validates."
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(2000), 13))
  let assert Ok(key) =
    command.service_key(
      parent,
      role,
      scope,
      remote_tool.operation(parent),
      step,
      id,
      string.repeat(input, 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "The original physical service validates."
  key
}

pub fn complete_identity_roundtrip_and_closed_pair_test() {
  list.each([command.CompileService, command.LaunchService], fn(role) {
    let key = make_service(role, "a")
    assert command.decode_service(command.encode_service(key)) == Ok(key)
    let command_role = case role {
      command.CompileService -> command.CompileCommand
      command.LaunchService -> command.SatelliteCommand
    }
    let assert Ok(ref) = command.command_ref(key, command_role)
      as "The closed pair validates."
    assert command.decode_ref(command.encode_ref(ref)) == Ok(ref)
    assert command.parent(command.service(ref)) == parent()
    assert command.coordinates(key).1 == remote_tool.operation(parent())
  })
  assert command.command_ref(
      make_service(command.CompileService, "a"),
      command.SatelliteCommand,
    )
    |> result.is_error
  assert command.command_ref(
      make_service(command.LaunchService, "a"),
      command.CompileCommand,
    )
    |> result.is_error
}

pub fn address_excludes_changed_input_and_uuid_but_retains_purpose_test() {
  let a = make_service(command.CompileService, "a")
  let b = make_service(command.CompileService, "b")
  let assert Ok(ar) = command.command_ref(a, command.CompileCommand)
    as "Compile reference validates."
  let assert Ok(br) = command.command_ref(b, command.CompileCommand)
    as "Changed input still validates as identity."
  assert command.command_address(ar) == command.command_address(br)
  assert command.encode_ref(ar) != command.encode_ref(br)
  let launch = make_service(command.LaunchService, "a")
  let assert Ok(lr) = command.command_ref(launch, command.SatelliteCommand)
    as "Launch reference validates."
  assert command.command_address(ar) != command.command_address(lr)
  assert remote_tool.child_address(command.service_origin(a))
    != remote_tool.child_address(command.native_origin(ar))
}

pub fn malformed_identity_cannot_change_parent_operation_session_or_roles_test() {
  let key = make_service(command.CompileService, "a")
  let #(scope, operation, step) = command.coordinates(key)
  let #(other, _) = ids.mint_op(ids.generator(clock.fixed(3000), 33))
  assert command.service_key(
      parent(),
      command.CompileService,
      scope,
      other,
      step,
      command.request_id(key),
      string.repeat("a", 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    |> result.is_error
  let assert json.Array(fields) = command.encode_service(key)
    as "The closed identity is an array."
  let changed =
    list.index_map(fields, fn(field, index) {
      case index {
        4 -> json.String(ids.op_id_to_string(other))
        _ -> field
      }
    })
  assert command.decode_service(json.Array(changed)) |> result.is_error
  assert command.decode_service(json.Array(list.append(fields, [json.Null])))
    |> result.is_error
  let #(other_session, _) =
    ids.mint_session(ids.generator(clock.fixed(4000), 44))
  let assert Ok(other_scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(other_session),
      "repo",
      "executor",
      2,
      3,
    )
    as "An independently valid foreign scope exists."
  assert command.service_key(
      parent(),
      command.CompileService,
      other_scope,
      operation,
      step,
      command.request_id(key),
      string.repeat("a", 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    |> result.is_error
  assert command.decode_ref(
      json.Array([
        json.Int(1),
        command.encode_service(key),
        json.String("satellite_command"),
      ]),
    )
    |> result.is_error
  assert command.digest(string.repeat("A", 64)) |> result.is_error
  assert command.digest(string.repeat("z", 64)) |> result.is_error
  assert command.digest(string.repeat("a", 63)) |> result.is_error
}

/// Only two addresses are available; a rewrite cannot become another predecessor.
pub fn bounded_rewrite_keeps_original_coordinates_and_rejects_nesting_test() {
  let original = make_service(command.CompileService, "a")
  let #(rewrite_id, _) = ids.mint_entry(ids.generator(clock.fixed(3000), 34))
  let assert Ok(rewrite) =
    command.rewrite_service_key(original, rewrite_id, string.repeat("d", 64))
    as "The sole rewritten attempt derives from the Original key."
  assert command.parent(rewrite) == command.parent(original)
  assert command.coordinates(rewrite) == command.coordinates(original)
  assert command.compile_predecessor(rewrite) == option.Some(original)
  assert command.decode_service(command.encode_service(rewrite)) == Ok(rewrite)
  let assert Ok(original_ref) =
    command.command_ref(original, command.CompileCommand)
    as "Original native role."
  let assert Ok(rewrite_ref) =
    command.command_ref(rewrite, command.CompileCommand)
    as "Rewrite native role."
  assert command.native_origin(original_ref)
    != command.native_origin(rewrite_ref)
  assert command.service_origin(original) != command.service_origin(rewrite)
  assert remote_tool.child_address(command.service_origin(rewrite))
    == json.to_string(
      json.Array([
        json.String(remote_tool.address(command.parent(original))),
        json.Array([json.String("compile_unused_import_rewrite")]),
      ]),
    )
  assert command.rewrite_service_key(
      rewrite,
      command.request_id(original),
      string.repeat("e", 64),
    )
    |> result.is_error
  assert command.rewrite_service_key(
      original,
      command.request_id(original),
      string.repeat("e", 64),
    )
    |> result.is_error
  assert command.rewrite_service_key(
      make_service(command.LaunchService, "a"),
      rewrite_id,
      string.repeat("e", 64),
    )
    |> result.is_error
  assert command.decode_service(
      json.Array([
        json.Int(2),
        command.encode_service(rewrite),
        json.String(ids.entry_id_to_string(rewrite_id)),
        json.String(string.repeat("e", 64)),
      ]),
    )
    |> result.is_error
}

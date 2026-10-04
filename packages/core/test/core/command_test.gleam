//// Pure service identity controls separate deterministic addresses from content.

import core/clock
import core/command
import core/ids
import core/json
import core/remote_tool
import core/workspace
import gleam/list
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

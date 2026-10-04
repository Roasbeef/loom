//// Exact identity and location receipts for remote physical preparation.
////
//// These data-only records prove equality with the trusted enrollment's
//// versioned layout. They do not prove successful compilation, an existing
//// directory, a live listener, token custody or permission to recreate anything.
//// A journal's one preparation claim and the live resource owner supply those
//// separate facts. Decoding historical Ready bytes never restores that claim.
////
//// Compile retains its full service key and build allocation. Launch retains
//// both its full key and producing Compile key under the same original parent,
//// plus the fixed channel handles. Physical steps may differ. Admission compares
//// literal paths rather than normalizing aliases into accepted locations.
//// The closed MessagePack envelope reuses core's canonical service key arrays;
//// bounded scanning precedes decoding and byte equality rejects alternative
//// encodings. `decode_key` applies the shared full-identity decoder to each
//// embedded key. Original service input and artifact admission remain separate.

import broker/enrollment
import core/bounded_msgpack
import core/command
import core/json_wire
import core/msgpack as mp
import gleam/result

/// Exact Compile identity and build path, carrying no artifact or live authority.
pub opaque type CompileLocations {
  CompileLocations(
    /// Complete original Compile service identity.
    service: command.ServiceKey,
    /// Exact enrollment-derived allocation root.
    build_root: String,
  )
}

/// Exact Launch identity, producing Compile and channel paths, carrying no lease.
pub opaque type LaunchResources {
  LaunchResources(
    /// Complete original Launch service identity.
    service: command.ServiceKey,
    /// Complete producing Compile service identity under the same parent.
    compiled_by: command.ServiceKey,
    /// Exact enrollment-derived channel allocation.
    directory: String,
    /// Fixed socket pathname, without a listener handle.
    socket: String,
    /// Fixed token-file pathname, without authentication bytes.
    token: String,
  )
}

/// Closed historical location evidence. Ready names the protocol receipt only;
/// callers must separately establish preparation and current resource custody.
pub type Ready {
  /// Compile allocation equality, without a successful Compile completion.
  CompileReady(locations: CompileLocations)

  /// Launch channel equality, without a live listener or recreation authority.
  LaunchReady(resources: LaunchResources)
}

/// Refusal to decode bounded canonical metadata or to match trusted locations.
pub type Error {
  /// Unsupported, malformed, noncanonical or oversized metadata.
  Invalid

  /// A key or literal location differs from the trusted enrollment/parent.
  Mismatch
}

/// Admits the exact returned build allocation under trusted enrollment.
/// This performs no filesystem check and grants no preparation claim.
///
/// ## Examples
///
/// `admit_compile_locations(enrolled, compile, "/another/build")` is refused.
pub fn admit_compile_locations(
  enrolled: enrollment.SessionEnrollment,
  service: command.ServiceKey,
  returned_root: String,
) -> Result(CompileLocations, Error) {
  use expected <- result.try(
    enrollment.compile_path(enrolled, service)
    |> result.replace_error(Mismatch),
  )
  use Nil <- result.try(equal_path(returned_root, expected))
  Ok(CompileLocations(service:, build_root: expected))
}

/// Admits fixed Launch handles and its producing Compile's complete identity.
/// Both keys must bind this enrollment and retain the identical original parent.
/// The keys' physical steps need not agree. Artifact completion and fingerprint
/// checks remain with service input admission and the physical launcher.
///
/// ## Examples
///
/// `admit_launch_resources(enrolled, launch, compile, dir, sock, token)` checks
/// literal handles; an alias such as `dir <> "/./s"` is refused.
pub fn admit_launch_resources(
  enrolled: enrollment.SessionEnrollment,
  service: command.ServiceKey,
  compiled_by: command.ServiceKey,
  returned_directory: String,
  returned_socket: String,
  returned_token: String,
) -> Result(LaunchResources, Error) {
  use paths <- result.try(
    enrollment.launch_paths(enrolled, service)
    |> result.replace_error(Mismatch),
  )
  use _ <- result.try(
    enrollment.compile_path(enrolled, compiled_by)
    |> result.replace_error(Mismatch),
  )
  use Nil <- result.try(
    case command.parent(service) == command.parent(compiled_by) {
      True -> Ok(Nil)
      False -> Error(Mismatch)
    },
  )

  // All three independently returned handles must match the fixed layout.
  use Nil <- result.try(equal_path(returned_directory, paths.0))
  use Nil <- result.try(equal_path(returned_socket, paths.1))
  use Nil <- result.try(equal_path(returned_token, paths.2))
  Ok(LaunchResources(
    service:,
    compiled_by:,
    directory: paths.0,
    socket: paths.1,
    token: paths.2,
  ))
}

/// Returns the complete original Compile key and exact build root.
///
/// ## Examples
///
/// `compile_fields(locations).0` includes the original input digest and parent.
pub fn compile_fields(
  locations: CompileLocations,
) -> #(command.ServiceKey, String) {
  #(locations.service, locations.build_root)
}

/// Returns the complete original Launch and producing Compile keys.
///
/// ## Examples
///
/// `launch_keys(resources).1` names the producer without inventing another ID.
pub fn launch_keys(
  resources: LaunchResources,
) -> #(command.ServiceKey, command.ServiceKey) {
  #(resources.service, resources.compiled_by)
}

/// Returns the exact channel directory, socket path and private token-file path.
/// Token bytes and live handles are never present in the returned data.
///
/// ## Examples
///
/// `launch_paths(resources).1` ends in the versioned `/s` basename.
pub fn launch_paths(resources: LaunchResources) -> #(String, String, String) {
  #(resources.directory, resources.socket, resources.token)
}

/// Encodes a closed Ready receipt under core's fixed remote MessagePack bounds.
/// The frame contains only original keys and canonical path strings.
///
/// ## Examples
///
/// `decode(enrolled, encode(ready) |> result.unwrap(<<>>)) == Ok(ready)`.
pub fn encode(ready: Ready) -> Result(BitArray, Error) {
  use bytes <- result.try(
    mp.encode(to_value(ready)) |> result.replace_error(Invalid),
  )
  use _ <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  Ok(bytes)
}

/// Decodes historical location evidence against the caller's trusted enrollment.
/// Decoded values grant no native admission or authority to create resources.
/// Noncanonical MessagePack, unknown tags, extra fields and aliases are refused.
///
/// ## Examples
///
/// `decode(enrolled, <<0x91, 0xc0>>) == Error(Invalid)`.
pub fn decode(
  enrolled: enrollment.SessionEnrollment,
  bytes: BitArray,
) -> Result(Ready, Error) {
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  use ready <- result.try(from_value(enrolled, value))
  use canonical <- result.try(encode(ready))
  case canonical == bytes {
    True -> Ok(ready)
    False -> Error(Invalid)
  }
}

fn to_value(ready: Ready) -> mp.MsgPackValue {
  case ready {
    CompileReady(locations) ->
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("compile"),
        json_wire.of_json(command.encode_service(locations.service)),
        mp.StringValue(locations.build_root),
      ])
    LaunchReady(resources) ->
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("launch"),
        json_wire.of_json(command.encode_service(resources.service)),
        json_wire.of_json(command.encode_service(resources.compiled_by)),
        mp.StringValue(resources.directory),
        mp.StringValue(resources.socket),
        mp.StringValue(resources.token),
      ])
  }
}

fn from_value(
  enrolled: enrollment.SessionEnrollment,
  value: mp.MsgPackValue,
) -> Result(Ready, Error) {
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("compile"),
      key,
      mp.StringValue(root),
    ]) -> {
      use key <- result.try(decode_key(key))
      admit_compile_locations(enrolled, key, root) |> result.map(CompileReady)
    }
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("launch"),
      key,
      producer,
      mp.StringValue(directory),
      mp.StringValue(socket),
      mp.StringValue(token),
    ]) -> {
      use key <- result.try(decode_key(key))
      use producer <- result.try(decode_key(producer))
      admit_launch_resources(enrolled, key, producer, directory, socket, token)
      |> result.map(LaunchReady)
    }
    _ -> Error(Invalid)
  }
}

fn decode_key(value: mp.MsgPackValue) -> Result(command.ServiceKey, Error) {
  use value <- result.try(
    json_wire.to_json(value) |> result.replace_error(Invalid),
  )
  command.decode_service(value) |> result.replace_error(Invalid)
}

fn equal_path(returned: String, expected: String) -> Result(Nil, Error) {
  case returned == expected {
    True -> Ok(Nil)
    False -> Error(Mismatch)
  }
}

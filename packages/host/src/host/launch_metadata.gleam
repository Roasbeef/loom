//// The daemon records only the launch facts needed to reproduce its own
//// distribution mode. The record is private, bounded, and tied to the native
//// reservation and authenticated ready epoch; it is never replacement authority.

import core/json
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/endpoint

/// The distribution setting actually supplied to the daemon's emulator.
pub type Mode {
  /// No distribution boot options were supplied.
  LocalOnly

  /// The canonical private options file used for TLS distribution.
  Tls(options: String)
}

/// Nonsecret launch facts bound to one daemon incarnation.
pub type Record {
  Record(
    /// The endpoint's native process identity.
    fence: endpoint.Fence,
    /// The authenticated ready epoch of the daemon.
    epoch: String,
    /// The actual canonical configuration file, or absence of a file.
    config: Option(String),
    /// The original distribution boot mode.
    mode: Mode,
  )
}

/// Reads the private launch record. Absence never implies local-only mode.
///
/// ## Examples
///
/// ```gleam
/// // launch_metadata.load(paths)
/// ```
pub fn load(paths: endpoint.Paths) -> Result(Option(Record), String) {
  let path = paths.root <> "/launch.json"

  // A missing record is distinct from a deliberately local launch.
  case bootstrap.path_exists(path) {
    False -> Ok(None)
    True -> {
      use bytes <- result.try(bootstrap.read_private_bounded(path, 4096))
      use text <- result.try(
        bit_array.to_string(bytes)
        |> result.replace_error("invalid launch metadata"),
      )
      decode(text) |> result.map(Some)
    }
  }
}

/// Atomically writes a validated record while the caller holds launch.lock.
///
/// ## Examples
///
/// ```gleam
/// // launch_metadata.write(paths, record)
/// ```
pub fn write(paths: endpoint.Paths, record: Record) -> Result(Nil, String) {
  let text = encode(record)
  use _ <- result.try(decode(text))
  bootstrap.atomic_write_private(paths.root <> "/launch.json", text)
}

/// Writes representable metadata, leaving this epoch without a record when
/// its encoded facts exceed the schema bounds. Filesystem failures still fail.
///
/// ## Examples
///
/// ```gleam
/// // launch_metadata.write_representable(paths, record)
/// ```
pub fn write_representable(
  paths: endpoint.Paths,
  record: Record,
) -> Result(Nil, String) {
  let text = encode(record)

  // An unsupported schema value cannot authorize an automatic replacement.
  case decode(text) {
    Ok(_) -> bootstrap.atomic_write_private(paths.root <> "/launch.json", text)
    Error(_) -> Ok(Nil)
  }
}

/// Encodes nonsecret launch facts as bounded versioned JSON.
///
/// ## Examples
///
/// ```gleam
/// // launch_metadata.decode(launch_metadata.encode(record)) == Ok(record)
/// ```
pub fn encode(record: Record) -> String {
  // Absence must remain distinct from a file path.
  let config = case record.config {
    None -> json.Null
    Some(path) -> json.String(path)
  }

  // Local-only carries no TLS options path.
  let #(mode, options) = case record.mode {
    LocalOnly -> #("local", json.Null)
    Tls(options:) -> #("tls", json.String(options))
  }

  json.to_string(
    json.Object([
      #("version", json.Int(1)),
      #("pid", json.Int(record.fence.pid)),
      #("birth", json.String(record.fence.birth)),
      #("started_at_ms", json.Int(record.fence.started_at_ms)),
      #("epoch", json.String(record.epoch)),
      #("config", config),
      #("mode", json.String(mode)),
      #("options", options),
    ]),
  )
}

/// Decodes only the complete first schema and rejects oversized records.
///
/// ## Examples
///
/// ```gleam
/// launch_metadata.decode("{}") // Error("invalid launch metadata")
/// ```
pub fn decode(text: String) -> Result(Record, String) {
  use <- bool.guard(
    string.byte_size(text) > 4096,
    Error("invalid launch metadata"),
  )
  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid launch metadata"),
  )

  // A fixed field count plus the parser's duplicate-key refusal closes the schema.
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid launch metadata")
  })

  use <- bool.guard(list.length(fields) != 8, Error("invalid launch metadata"))
  use version <- result.try(number(fields, "version"))
  use pid <- result.try(number(fields, "pid"))
  use started <- result.try(number(fields, "started_at_ms"))
  use birth <- result.try(text_field(fields, "birth"))
  use epoch <- result.try(text_field(fields, "epoch"))
  use mode <- result.try(text_field(fields, "mode"))
  use config <- result.try(optional_path(fields, "config"))
  use options <- result.try(optional_path(fields, "options"))
  use <- bool.guard(
    version != 1
      || pid <= 1
      || started <= 0
      || birth == ""
      || string.byte_size(birth) > 256
      || epoch == ""
      || string.byte_size(epoch) > 256,
    Error("invalid launch metadata"),
  )

  // The mode and its options path are one closed choice.
  use launch <- result.try(case mode, options {
    "local", None -> Ok(LocalOnly)
    "tls", Some(path) -> Ok(Tls(path))
    _, _ -> Error("invalid launch metadata")
  })

  Ok(Record(endpoint.Fence(pid, birth, started), epoch, config, launch))
}

fn field(fields, key) {
  list.key_find(fields, key) |> result.replace_error("invalid launch metadata")
}

/// Extracts a required integer without coercion.
fn number(fields, key) {
  use value <- result.try(field(fields, key))

  // Other JSON shapes cannot represent this integer.
  case value {
    json.Int(value) -> Ok(value)
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid launch metadata")
  }
}

/// Extracts a required string without coercion.
fn text_field(fields, key) {
  use value <- result.try(field(fields, key))

  // Other JSON shapes cannot represent this string.
  case value {
    json.String(value) -> Ok(value)
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid launch metadata")
  }
}

/// Accepts an absent path or a bounded absolute path.
fn optional_path(fields, key) {
  use value <- result.try(field(fields, key))

  // Null records absence; a string must name an absolute path.
  case value {
    json.Null -> Ok(None)
    json.String(path) -> {
      use <- bool.guard(
        !string.starts_with(path, "/") || string.byte_size(path) > 2048,
        Error("invalid launch metadata"),
      )
      Ok(Some(path))
    }
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_) -> Error("invalid launch metadata")
  }
}

//// Daemon connection admission settings, captured once before startup.
////
//// Every socket reserves its maximum inbound message and retained delivery
//// allowance. The aggregate is a bound on admitted payload capacity, not an
//// allocation or an RSS estimate. Session configuration cannot change a running
//// daemon's limits; the owner's startup configuration is the only input.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tom

/// Independent ceilings for socket count and potential message payload.
pub type Limits {
  Limits(
    /// Maximum reserved HTTP upgrades and admitted WebSockets combined.
    connections: Int,
    /// Aggregate inbound and retained delivery allowance, in bytes.
    reserved_message_bytes: Int,
  )
}

/// Defaults leave room for twelve operator/control terminal pairs.
pub const defaults = Limits(64, 536_870_912)

/// Rejects nonpositive settings before the daemon acquires any resources.
///
/// ## Examples
///
/// ```gleam
/// assert limits.validate(limits.defaults) == Ok(Nil)
/// ```
pub fn validate(limits: Limits) -> Result(Nil, String) {
  case limits.connections > 0, limits.reserved_message_bytes > 0 {
    False, _ -> Error("daemon.max_connections must be a positive integer")
    True, False ->
      Error("daemon.max_reserved_message_bytes must be a positive integer")
    True, True -> Ok(Nil)
  }
}

/// Reads daemon limits without requiring a model catalogue to exist.
///
/// ## Examples
///
/// ```gleam
/// assert limits.parse("") == Ok(limits.defaults)
/// ```
pub fn parse(text: String) -> Result(Limits, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the shared daemon table for startup and catalogue loading alike.
///
/// Profiling is launcher-owned, but its type belongs to this same table's
/// contract. Omission keeps profiling disabled and each limit at its default.
///
/// ## Examples
///
/// ```gleam
/// assert limits.from_document(dict.new()) == Ok(limits.defaults)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Limits, String) {
  case dict.get(document, "daemon") {
    Error(Nil) -> Ok(defaults)
    Ok(tom.Table(fields)) -> from_fields(fields)
    Ok(_) -> Error("daemon must be a [daemon] table")
  }
}

fn from_fields(fields: Dict(String, tom.Toml)) -> Result(Limits, String) {
  use _ <- result.try(
    list.try_map(dict.keys(fields), fn(key) {
      case key {
        "profile" | "max_connections" | "max_reserved_message_bytes" -> Ok(Nil)
        _ -> Error("unknown key `" <> key <> "` in [daemon]")
      }
    }),
  )
  use Nil <- result.try(case dict.get(fields, "profile") {
    Error(Nil) | Ok(tom.Bool(_)) -> Ok(Nil)
    Ok(_) -> Error("daemon.profile must be true or false")
  })
  use connections <- result.try(positive(
    fields,
    "max_connections",
    defaults.connections,
  ))
  use reserved_message_bytes <- result.try(positive(
    fields,
    "max_reserved_message_bytes",
    defaults.reserved_message_bytes,
  ))
  Ok(Limits(connections:, reserved_message_bytes:))
}

fn positive(fields, key, default) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(default)
    Ok(tom.Int(value)) if value > 0 -> Ok(value)
    Ok(_) -> Error("daemon." <> key <> " must be a positive integer")
  }
}

/// Describes the exhausted count ceiling without exposing session metadata.
///
/// ## Examples
///
/// ```gleam
/// limits.count_refusal(limits.defaults)
/// ```
pub fn count_refusal(limits: Limits) -> String {
  "daemon connection limit reached (daemon.max_connections = "
  <> int.to_string(limits.connections)
  <> "); close another terminal or raise the setting and restart the daemon"
}

/// Describes the exhausted payload ceiling without implying allocated memory.
///
/// ## Examples
///
/// ```gleam
/// limits.bytes_refusal(limits.defaults)
/// ```
pub fn bytes_refusal(limits: Limits) -> String {
  "daemon connection message budget reached (daemon.max_reserved_message_bytes = "
  <> int.to_string(limits.reserved_message_bytes)
  <> "); close another terminal or raise the setting and restart the daemon"
}

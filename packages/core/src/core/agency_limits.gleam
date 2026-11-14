//// Per-session subagent concurrency and depth limits shared across storage,
//// daemon control protocol, and the terminal and web user interfaces.
////
//// Kept in `core` (pure, portable across Erlang and JavaScript) so every
//// client and storage boundary speaks the same validated types without taking
//// a runtime or database dependency.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Default concurrent live children allowed per parent strand.
pub const default_fan_out = 100

/// Default concurrent live spawned strands allowed in one session.
pub const default_session_strands = 256

/// Default spawn depth limit (only `main` at depth 0 spawns children).
pub const default_depth_cap = 1

/// Upper bound admitted on per-session `fan_out` overrides.
pub const max_fan_out = 10_000

/// Upper bound admitted on per-session `session_strands` overrides.
pub const max_session_strands = 10_000

/// Upper bound admitted on finite `BoundedDepth` overrides and ancestor walks.
pub const max_depth_cap = 256

/// How deeply a session allows strands to spawn subagents.
pub type DepthCap {
  /// Spawns are admitted up to `depth` (counting `main` as depth 0).
  BoundedDepth(depth: Int)

  /// No depth limit is enforced; recursive spawning is bounded by
  /// `session_strands` and `max_depth_cap` ancestor walks.
  UnlimitedDepth
}

/// Optional per-session overrides for Agency fan-out, session capacity, and depth.
///
/// `None` in any slot inherits the host/Agency default.
pub type AgencyLimits {
  AgencyLimits(
    fan_out: Option(Int),
    session_strands: Option(Int),
    depth_cap: Option(DepthCap),
  )
}

/// Resolved effective per-session Agency caps after applying defaults.
pub type EffectiveLimits {
  EffectiveLimits(fan_out: Int, session_strands: Int, depth_cap: DepthCap)
}

/// Empty limits constant inheriting every Agency default.
pub const empty =
  AgencyLimits(fan_out: None, session_strands: None, depth_cap: None)

/// Empty overrides: inherit every Agency default.
///
/// ## Examples
///
/// ```gleam
/// assert agency_limits.is_empty(agency_limits.defaults())
/// ```
pub fn defaults() -> AgencyLimits {
  AgencyLimits(fan_out: None, session_strands: None, depth_cap: None)
}

/// Whether all three limit overrides are absent.
///
/// ## Examples
///
/// ```gleam
/// assert agency_limits.is_empty(agency_limits.defaults())
/// assert !agency_limits.is_empty(agency_limits.AgencyLimits(Some(10), None, None))
/// ```
pub fn is_empty(limits: AgencyLimits) -> Bool {
  limits.fan_out == None
  && limits.session_strands == None
  && limits.depth_cap == None
}

/// Validates that any present overrides fall within accepted bounds and that
/// `fan_out` does not exceed `session_strands` when both are specified.
///
/// ## Examples
///
/// ```gleam
/// assert agency_limits.validate(agency_limits.defaults())
///   == Ok(agency_limits.defaults())
/// ```
pub fn validate(limits: AgencyLimits) -> Result(AgencyLimits, String) {
  use fan_out <- result.try(validate_fan_out(limits.fan_out))
  use session_strands <- result.try(validate_session_strands(
    limits.session_strands,
  ))
  use depth_cap <- result.try(validate_depth_cap(limits.depth_cap))

  // When both live caps are explicit, per-parent fan-out cannot exceed total strands.
  case fan_out, session_strands {
    Some(f), Some(s) if f > s ->
      Error("agency.fan_out cannot exceed agency.session_strands")
    _, _ -> Ok(AgencyLimits(fan_out:, session_strands:, depth_cap:))
  }
}

/// Resolves optional overrides against shipped defaults, raising default
/// `session_strands` if an explicit `fan_out` exceeds `default_session_strands`.
///
/// ## Examples
///
/// ```gleam
/// assert agency_limits.resolve(agency_limits.empty)
///   == agency_limits.EffectiveLimits(100, 256, agency_limits.BoundedDepth(1))
/// ```
pub fn resolve(limits: AgencyLimits) -> EffectiveLimits {
  let fan_out = option.unwrap(limits.fan_out, default_fan_out)

  // Keep default session_strands at least as large as an explicit fan_out.
  let session_strands = case limits.session_strands {
    Some(value) -> value
    None -> int.max(default_session_strands, fan_out)
  }

  let depth_cap =
    option.unwrap(limits.depth_cap, BoundedDepth(default_depth_cap))
  EffectiveLimits(fan_out:, session_strands:, depth_cap:)
}

/// Encodes non-empty overrides as a JSON object for the control wire.
///
/// ## Examples
///
/// ```gleam
/// // agency_limits.encode_json(agency_limits.defaults())
/// ```
pub fn encode_json(limits: AgencyLimits) -> JsonValue {
  // Only populate keys that are explicitly overridden.
  let fan_out = case limits.fan_out {
    None -> []
    Some(value) -> [#("fan_out", json.Int(value))]
  }

  // Encode session-wide strand cap when overridden.
  let session_strands = case limits.session_strands {
    None -> []
    Some(value) -> [#("session_strands", json.Int(value))]
  }

  // Encode bounded integers or the "unlimited" marker for recursive spawning.
  let depth_cap = case limits.depth_cap {
    None -> []
    Some(BoundedDepth(depth)) -> [#("depth_cap", json.Int(depth))]
    Some(UnlimitedDepth) -> [#("depth_cap", json.String("unlimited"))]
  }

  json.Object(list.flatten([fan_out, session_strands, depth_cap]))
}

/// Decodes and validates an `"agency"` JSON object from the control wire.
///
/// ## Examples
///
/// ```gleam
/// // agency_limits.decode_json(json.Object([])) == Ok(agency_limits.defaults())
/// ```
pub fn decode_json(value: JsonValue) -> Result(AgencyLimits, String) {
  // Reject non-object payloads rather than silently falling back to defaults.
  case value {
    json.Object(fields) -> decode_fields(fields)
    _ -> Error("agency must be a JSON object")
  }
}

/// Parses a user-entered depth cap string (`"unlimited"` or positive integer).
///
/// ## Examples
///
/// ```gleam
/// assert agency_limits.parse_depth_cap("") == Ok(None)
/// assert agency_limits.parse_depth_cap("unlimited") == Ok(Some(agency_limits.UnlimitedDepth))
/// assert agency_limits.parse_depth_cap("3") == Ok(Some(agency_limits.BoundedDepth(3)))
/// ```
pub fn parse_depth_cap(raw: String) -> Result(Option(DepthCap), String) {
  let trimmed = string.trim(raw) |> string.lowercase

  // Empty string inherits default; "unlimited" disables depth cap; integers bound depth.
  case trimmed {
    "" -> Ok(None)
    "unlimited" -> Ok(Some(UnlimitedDepth))
    text -> {
      use depth <- result.try(
        int.parse(text)
        |> result.map_error(fn(_) {
          "depth_cap must be an integer (1.."
          <> int.to_string(max_depth_cap)
          <> ") or \"unlimited\""
        }),
      )
      use valid <- result.map(validate_depth_cap(Some(BoundedDepth(depth))))
      valid
    }
  }
}

/// Formats a `DepthCap` override for display in forms and summaries.
///
/// ## Examples
///
/// ```gleam
/// assert agency_limits.format_depth_cap(agency_limits.UnlimitedDepth) == "unlimited"
/// assert agency_limits.format_depth_cap(agency_limits.BoundedDepth(2)) == "2"
/// ```
pub fn format_depth_cap(cap: DepthCap) -> String {
  case cap {
    BoundedDepth(depth) -> int.to_string(depth)
    UnlimitedDepth -> "unlimited"
  }
}

/// Decodes and validates the fields of an `"agency"` JSON object.
fn decode_fields(
  fields: List(#(String, JsonValue)),
) -> Result(AgencyLimits, String) {
  let allowed = ["fan_out", "session_strands", "depth_cap"]

  // Reject unknown keys to catch typos in control clients early.
  use Nil <- result.try(
    list.try_each(fields, fn(pair) {
      case list.contains(allowed, pair.0) {
        True -> Ok(Nil)
        False -> Error("unknown agency field: " <> pair.0)
      }
    }),
  )
  use fan_out <- result.try(decode_optional_int(fields, "fan_out"))
  use session_strands <- result.try(decode_optional_int(
    fields,
    "session_strands",
  ))
  use depth_cap <- result.try(decode_optional_depth(fields))

  validate(AgencyLimits(fan_out:, session_strands:, depth_cap:))
}

/// Decodes an optional integer field from a JSON field list.
fn decode_optional_int(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(Int), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(value)) -> Ok(Some(value))
    Ok(_) -> Error("agency." <> key <> " must be an integer")
  }
}

/// Decodes an optional integer or `"unlimited"` `depth_cap` field.
fn decode_optional_depth(
  fields: List(#(String, JsonValue)),
) -> Result(Option(DepthCap), String) {
  case list.key_find(fields, "depth_cap") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(depth)) -> Ok(Some(BoundedDepth(depth)))
    Ok(json.String(text)) ->
      case string.lowercase(string.trim(text)) {
        "unlimited" -> Ok(Some(UnlimitedDepth))
        _ -> Error("agency.depth_cap string must be \"unlimited\"")
      }
    Ok(_) -> Error("agency.depth_cap must be an integer or \"unlimited\"")
  }
}

/// Validates an optional `fan_out` bound against `1..max_fan_out`.
fn validate_fan_out(value: Option(Int)) -> Result(Option(Int), String) {
  case value {
    None -> Ok(None)
    Some(n) if n >= 1 && n <= max_fan_out -> Ok(Some(n))
    Some(_) ->
      Error(
        "agency.fan_out must be between 1 and " <> int.to_string(max_fan_out),
      )
  }
}

/// Validates an optional `session_strands` bound against `1..max_session_strands`.
fn validate_session_strands(value: Option(Int)) -> Result(Option(Int), String) {
  case value {
    None -> Ok(None)
    Some(n) if n >= 1 && n <= max_session_strands -> Ok(Some(n))
    Some(_) ->
      Error(
        "agency.session_strands must be between 1 and "
        <> int.to_string(max_session_strands),
      )
  }
}

/// Validates an optional `DepthCap` bound against `1..max_depth_cap` or unlimited.
fn validate_depth_cap(
  value: Option(DepthCap),
) -> Result(Option(DepthCap), String) {
  case value {
    None -> Ok(None)
    Some(UnlimitedDepth) -> Ok(Some(UnlimitedDepth))
    Some(BoundedDepth(n)) if n >= 1 && n <= max_depth_cap ->
      Ok(Some(BoundedDepth(n)))
    Some(BoundedDepth(_)) ->
      Error(
        "agency.depth_cap must be between 1 and "
        <> int.to_string(max_depth_cap)
        <> " or \"unlimited\"",
      )
  }
}

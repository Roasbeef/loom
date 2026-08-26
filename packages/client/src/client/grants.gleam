//// The grant-JSON bridge: decoding the opaque escalation payloads the
//// runtime stores back into typed `broker/policy.Grant` values, and
//// encoding them back.
////
//// The runtime records escalations with the denial and grants as opaque
//// JSON in the broker's escalation vocabulary (`tools/tool.grant_to_json`
//// / `denial_to_json`: `grant`-discriminated objects, limit fields named
//// `cpu_s`, `wall_s`, ..., scratch as a bare string). Spec-gaps ("From
//// the M3 runtime wave", item 4) leaves decoding that JSON back to
//// `policy.Grant` to the gateway wave — this module is that wiring. It
//// lets the gateway
////
//// - surface a stored denial's `wanted` diff as typed grants in the
////   protocol's `type`-discriminated wire vocabulary
////   (`client/protocol.encode_grant`),
//// - validate an `approve` command's grants structurally against the
////   wanted diff, and
//// - store approved grants back in the internal vocabulary, so the
////   consume path (`runtime/effects.ClearanceQuery.grants` → tool
////   `Ctx.grants`) hands re-executions exactly what was approved.
////
//// Everything here is pure and total.

import broker/escalation
import broker/policy.{type Grant}
import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A decoded internal denial: the typed view of the JSON the runtime
/// stores for a raised escalation.
///
/// Constructor invariants: `source` is `PolicyDenial` or
/// `ExecutionDenial` (the stored JSON does not carry the enforcement
/// list, so `ExecutionDenial` decodes with an empty one); `wanted` is
/// the exact widening that would satisfy the denial.
pub type DecodedDenial {
  DecodedDenial(
    reason: String,
    source: escalation.DenialSource,
    wanted: List(Grant),
  )
}

/// Encodes one grant in the internal escalation vocabulary — the byte
/// shape `tools/tool.grant_to_json` produces and the runtime stores.
///
/// ## Examples
///
/// ```gleam
/// assert grants.encode(policy.GrantEnv(name: "PATH"))
///   == json.Object([
///     #("grant", json.String("env")),
///     #("name", json.String("PATH")),
///   ])
/// ```
///
pub fn encode(grant: Grant) -> JsonValue {
  case grant {
    policy.GrantWritableRoot(path:) ->
      json.Object([
        #("grant", json.String("writable_root")),
        #("path", json.String(path)),
      ])
    policy.GrantReadableRoot(path:) ->
      json.Object([
        #("grant", json.String("readable_root")),
        #("path", json.String(path)),
      ])
    policy.GrantNetwork(network:) ->
      json.Object([
        #("grant", json.String("network")),
        #("network", encode_network(network)),
      ])
    policy.GrantEnv(name:) ->
      json.Object([
        #("grant", json.String("env")),
        #("name", json.String(name)),
      ])
    policy.GrantLimit(field:, value:) ->
      json.Object([
        #("grant", json.String("limit")),
        #("field", json.String(limit_field_text(field))),
        #("value", json.Int(value)),
      ])
    policy.GrantScratch(scratch:) ->
      json.Object([
        #("grant", json.String("scratch")),
        #("scratch", json.String(scratch_text(scratch))),
      ])
  }
}

/// Decodes one grant from the internal escalation vocabulary. Total:
/// malformed payloads are corruption reports, never crashes.
///
/// ## Examples
///
/// ```gleam
/// assert grants.decode(grants.encode(policy.GrantEnv(name: "PATH")))
///   == Ok(policy.GrantEnv(name: "PATH"))
/// ```
///
pub fn decode(value: JsonValue) -> Result(Grant, CorruptionReport) {
  let where = "client/grants.decode"
  use fields <- result.try(fields_of(value, where))
  use kind <- result.try(require_string(fields, "grant", where))
  case kind {
    "writable_root" -> {
      use path <- result.try(require_string(fields, "path", where))
      Ok(policy.GrantWritableRoot(path:))
    }
    "readable_root" -> {
      use path <- result.try(require_string(fields, "path", where))
      Ok(policy.GrantReadableRoot(path:))
    }
    "network" -> {
      use network_value <- result.try(require(fields, "network", where))
      use network <- result.try(decode_network(network_value, where))
      Ok(policy.GrantNetwork(network:))
    }
    "env" -> {
      use name <- result.try(require_string(fields, "name", where))
      Ok(policy.GrantEnv(name:))
    }
    "limit" -> {
      use field_text <- result.try(require_string(fields, "field", where))
      use field <- result.try(parse_limit_field(field_text, where))
      use value <- result.try(require_int(fields, "value", where))
      Ok(policy.GrantLimit(field:, value:))
    }
    "scratch" -> {
      use scratch_text <- result.try(require_string(fields, "scratch", where))
      case scratch_text {
        "tmpfs" -> Ok(policy.GrantScratch(scratch: policy.ScratchTmpfs))
        path -> Ok(policy.GrantScratch(scratch: policy.ScratchPath(path: path)))
      }
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "grant",
        expected: "a known grant discriminator",
        context: other,
      ))
  }
}

/// Decodes a list of internal grant payloads (the `grants` field of a
/// stored escalation record).
///
/// ## Examples
///
/// ```gleam
/// assert grants.decode_all([grants.encode(policy.GrantEnv("PATH"))])
///   == Ok([policy.GrantEnv("PATH")])
/// ```
///
pub fn decode_all(
  values: List(JsonValue),
) -> Result(List(Grant), CorruptionReport) {
  list.try_map(values, decode)
}

/// Decodes a stored denial payload (`tools/tool.denial_to_json` shape:
/// `{error, reason, source, wanted}`) into its typed view.
///
/// ## Examples
///
/// ```gleam
/// // grants.decode_denial(stored) == Ok(grants.DecodedDenial(..))
/// ```
///
pub fn decode_denial(
  value: JsonValue,
) -> Result(DecodedDenial, CorruptionReport) {
  let where = "client/grants.decode_denial"
  use fields <- result.try(fields_of(value, where))
  use reason <- result.try(require_string(fields, "reason", where))
  use source_text <- result.try(require_string(fields, "source", where))
  use source <- result.try(case source_text {
    "policy" -> Ok(escalation.PolicyDenial)
    // The stored form does not carry the helper's enforcement list.
    "execution" -> Ok(escalation.ExecutionDenial(enforcement: []))
    other ->
      Error(corruption.report(
        at: where,
        on: "source",
        expected: "policy or execution",
        context: other,
      ))
  })
  use wanted_value <- result.try(require(fields, "wanted", where))
  use wanted <- result.try(case wanted_value {
    json.Array(items) -> decode_all(items)
    other ->
      Error(corruption.report(
        at: where,
        on: "wanted",
        expected: "an array of grants",
        context: json.to_string(other),
      ))
  })
  Ok(DecodedDenial(reason:, source:, wanted:))
}

/// Encodes a denial in the internal vocabulary (the shape
/// `tools/tool.denial_to_json` produces) — used by compositions that
/// raise escalations directly, such as the demo.
///
/// ## Examples
///
/// ```gleam
/// // grants.encode_denial("network off", escalation.PolicyDenial, wanted)
/// ```
///
pub fn encode_denial(
  reason reason: String,
  source source: escalation.DenialSource,
  wanted wanted: List(Grant),
) -> JsonValue {
  json.Object([
    #("error", json.String("policy_refused")),
    #("reason", json.String(reason)),
    #(
      "source",
      json.String(case source {
        escalation.PolicyDenial -> "policy"
        escalation.ExecutionDenial(enforcement: _) -> "execution"
      }),
    ),
    #("wanted", json.Array(list.map(wanted, encode))),
  ])
}

/// Whether every grant in `granted` appears structurally in `wanted` —
/// the approval-bound check (`approve` answers the surfaced diff and
/// nothing wider). Returns the first grant outside the diff.
///
/// ## Examples
///
/// ```gleam
/// assert grants.first_unwanted([policy.GrantEnv("PATH")], wanted: [])
///   == option.Some(policy.GrantEnv("PATH"))
/// ```
///
pub fn first_unwanted(
  granted: List(Grant),
  wanted wanted: List(Grant),
) -> Option(Grant) {
  case list.find(granted, fn(grant) { !list.contains(wanted, grant) }) {
    Ok(grant) -> Some(grant)
    Error(Nil) -> None
  }
}

// --- internal vocabulary details -------------------------------------------

fn encode_network(network: policy.NetworkPolicy) -> JsonValue {
  case network {
    policy.NetworkOff -> json.Object([#("mode", json.String("off"))])
    policy.NetworkFull -> json.Object([#("mode", json.String("full"))])
    policy.NetworkProxy(allow:, proxy:) ->
      json.Object([
        #("mode", json.String("proxy")),
        #("allow", json.Array(list.map(allow, json.String))),
        #("proxy", json.String(proxy)),
      ])
  }
}

fn host_glob(
  where: String,
  item: JsonValue,
) -> Result(String, CorruptionReport) {
  case item {
    json.String(host) -> Ok(host)
    other ->
      Error(corruption.report(
        at: where,
        on: "allow",
        expected: "string host globs",
        context: json.to_string(other),
      ))
  }
}

fn decode_network(
  value: JsonValue,
  where: String,
) -> Result(policy.NetworkPolicy, CorruptionReport) {
  use fields <- result.try(fields_of(value, where))
  use mode <- result.try(require_string(fields, "mode", where))
  case mode {
    "off" -> Ok(policy.NetworkOff)
    "full" -> Ok(policy.NetworkFull)
    "proxy" -> {
      use allow <- result.try(case list.key_find(fields, "allow") {
        Error(Nil) -> Ok([])
        Ok(json.Array(items)) -> list.try_map(items, host_glob(where, _))
        Ok(other) ->
          Error(corruption.report(
            at: where,
            on: "allow",
            expected: "an array of host globs",
            context: json.to_string(other),
          ))
      })
      use proxy <- result.try(require_string(fields, "proxy", where))
      Ok(policy.NetworkProxy(allow:, proxy:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "mode",
        expected: "off, proxy, or full",
        context: other,
      ))
  }
}

// The internal vocabulary uses the wire limit names (`cpu_s`, ...),
// matching `tools/tool.grant_to_json`.
fn limit_field_text(field: policy.LimitField) -> String {
  case field {
    policy.CpuSeconds -> "cpu_s"
    policy.WallSeconds -> "wall_s"
    policy.MemBytes -> "mem_bytes"
    policy.Pids -> "pids"
    policy.FsizeBytes -> "fsize_bytes"
    policy.OutputBytes -> "output_bytes"
  }
}

fn parse_limit_field(
  text: String,
  where: String,
) -> Result(policy.LimitField, CorruptionReport) {
  case text {
    "cpu_s" -> Ok(policy.CpuSeconds)
    "wall_s" -> Ok(policy.WallSeconds)
    "mem_bytes" -> Ok(policy.MemBytes)
    "pids" -> Ok(policy.Pids)
    "fsize_bytes" -> Ok(policy.FsizeBytes)
    "output_bytes" -> Ok(policy.OutputBytes)
    other ->
      Error(corruption.report(
        at: where,
        on: "field",
        expected: "a known limit field",
        context: other,
      ))
  }
}

fn scratch_text(scratch: policy.Scratch) -> String {
  case scratch {
    policy.ScratchTmpfs -> "tmpfs"
    policy.ScratchPath(path:) -> path
  }
}

fn fields_of(
  value: JsonValue,
  where: String,
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  case value {
    json.Object(fields) -> Ok(fields)
    other ->
      Error(corruption.report(
        at: where,
        on: "payload",
        expected: "a json object",
        context: json.to_string(other),
      ))
  }
}

fn require(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(JsonValue, CorruptionReport) {
  case list.key_find(fields, key) {
    Ok(value) -> Ok(value)
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a present field",
        context: "absent",
      ))
  }
}

fn require_string(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(String, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.String(text) -> Ok(text)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a string",
        context: json.to_string(other),
      ))
  }
}

fn require_int(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Int, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Int(number) -> Ok(number)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "an integer",
        context: json.to_string(other),
      ))
  }
}

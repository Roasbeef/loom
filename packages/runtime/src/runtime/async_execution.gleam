//// Durable custody of an execution whose satellite is volatile.
////
//// The session service owns the live worker; this record owns admission.
//// Child-run transactions compare its sequence, so changing it to Draining
//// fences new work before cleanup scans the children. Recovery never treats a
//// saved live record as proof that its satellite survived.

import core/corruption
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/list
import gleam/result
import gleam/string

/// The reserved namespace for execution records and their input values.
pub const prefix = "client/async/"

/// The lifecycle written by the execution service.
pub type Phase {
  /// Admission is durable, but the execution has not begun.
  Starting

  /// The worker may perform effects and admit children.
  Running

  /// No new effects or children may be admitted; cleanup is pending.
  Draining

  /// The worker and its owned children have settled.
  Finished(result: JsonValue)

  /// The worker was lost; this does not claim that effects completed.
  Lost(reason: String)
}

/// The durable identity and fixed terms of one execution.
pub type Execution {
  Execution(
    /// Stable handle derived by the harness from the launching call.
    id: String,
    /// Only this strand may interact with the handle.
    strand: String,
    /// The initiating operation, retained for operation-wide abort.
    operation: OpId,
    /// A separate broker step whose ledger outlives the launching batch.
    step: String,
    /// The absolute session-clock deadline, never renewed by interaction.
    deadline_ms: Int,
    /// The exact submitted source, retained for inspection.
    source: String,
    /// Which allowlist judged the program.
    seam: String,
    /// Current custody, rather than an inference from worker presence.
    phase: Phase,
  )
}

/// The immutable endpoint set a live execution has made ready.
pub type Readiness {
  Readiness(
    /// Names accepted by later host-side sends.
    endpoints: List(String),
    /// Typed service idle interval; zero belongs only to legacy raw receive.
    idle_within_ms: Int,
  )
}

/// Names the one authoritative execution record.
///
/// ## Examples
///
/// ```gleam
/// assert async_execution.key("abc") == "client/async/record/abc"
/// ```
pub fn key(id: String) -> String {
  prefix <> "record/" <> id
}

/// Names the immutable readiness fact published by the satellite.
///
/// ## Examples
///
/// ```gleam
/// assert async_execution.readiness_key("abc") == "client/async/ready/abc"
/// ```
pub fn readiness_key(id: String) -> String {
  prefix <> "ready/" <> id
}

/// Whether an endpoint name is bounded and safe in a durable fact.
///
/// ## Examples
///
/// ```gleam
/// assert async_execution.valid_endpoint("control.main")
/// ```
pub fn valid_endpoint(name: String) -> Bool {
  string.byte_size(name) > 0
  && string.byte_size(name) <= 64
  && list.all(string.to_graphemes(name), fn(char) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789._-", char)
  })
}

/// Validates the complete endpoint set before it becomes immutable.
///
/// ## Examples
///
/// ```gleam
/// assert async_execution.valid_endpoints(["default"])
/// ```
pub fn valid_endpoints(endpoints: List(String)) -> Bool {
  let count = list.length(endpoints)
  count > 0
  && count <= 16
  && list.all(endpoints, valid_endpoint)
  && list.length(list.unique(endpoints)) == count
}

/// Encodes one immutable readiness fact.
///
/// ## Examples
///
/// ```gleam
/// // async_execution.encode_readiness(Readiness(["default"], 0))
/// ```
pub fn encode_readiness(readiness: Readiness) -> JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #("endpoints", json.Array(list.map(readiness.endpoints, json.String))),
    #("idle_within_ms", json.Int(readiness.idle_within_ms)),
  ])
}

/// Decodes and validates one immutable readiness fact.
///
/// ## Examples
///
/// ```gleam
/// assert async_execution.decode_readiness(json.Null) |> result.is_error
/// ```
pub fn decode_readiness(value: JsonValue) -> Result(Readiness, String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("an object")
  })
  use version <- result.try(field(fields, "version"))
  use Nil <- result.try(case version {
    json.Int(1) -> Ok(Nil)
    _ -> Error("readiness version 1")
  })
  use encoded <- result.try(field(fields, "endpoints"))
  use endpoints <- result.try(case encoded {
    json.Array(values) ->
      list.try_map(values, fn(value) {
        case value {
          json.String(name) -> Ok(name)
          _ -> Error("text endpoint names")
        }
      })
    _ -> Error("an endpoint array")
  })
  use Nil <- result.try(case valid_endpoints(endpoints) {
    True -> Ok(Nil)
    False -> Error("one to sixteen unique bounded endpoint names")
  })
  use idle <- result.try(field(fields, "idle_within_ms"))
  use idle_within_ms <- result.try(case idle {
    json.Int(value) if value >= 0 && value <= 300_000 -> Ok(value)
    _ -> Error("an idle interval from 0 to 300000 ms")
  })
  use Nil <- result.try(case endpoints, idle_within_ms {
    ["default"], 0 -> Ok(Nil)
    _, value if value > 0 -> Ok(Nil)
    _, _ -> Error("zero idle only for the legacy default endpoint")
  })
  Ok(Readiness(endpoints:, idle_within_ms:))
}

/// Whether a handle can be used as one bounded fact-key component.
///
/// ## Examples
///
/// ```gleam
/// assert !async_execution.valid_id("../other")
/// ```
pub fn valid_id(id: String) -> Bool {
  string.byte_size(id) > 0
  && string.byte_size(id) <= 64
  && list.all(string.to_graphemes(id), fn(char) {
    string.contains("0123456789abcdef-", char)
  })
}

/// Whether admission is permitted at the supplied session-clock instant.
///
/// ## Examples
///
/// ```gleam
/// // async_execution.admits(record, now)
/// ```
pub fn admits(record: Execution, now: Int) -> Bool {
  record.phase == Running && now < record.deadline_ms
}

/// Whether an execution has no live worker to join.
///
/// ## Examples
///
/// ```gleam
/// assert async_execution.terminal(Lost("restart"))
/// ```
pub fn terminal(phase: Phase) -> Bool {
  case phase {
    Finished(_) | Lost(_) -> True
    Starting | Running | Draining -> False
  }
}

/// Encodes the complete record, including a version for later migrations.
///
/// ## Examples
///
/// ```gleam
/// // async_execution.decode(async_execution.encode(record)) == Ok(record)
/// ```
pub fn encode(record: Execution) -> JsonValue {
  let #(phase, result) = case record.phase {
    Starting -> #("starting", json.Null)
    Running -> #("running", json.Null)
    Draining -> #("draining", json.Null)
    Finished(value) -> #("finished", value)
    Lost(reason) -> #("lost", json.String(reason))
  }
  json.Object([
    #("version", json.Int(1)),
    #("id", json.String(record.id)),
    #("strand", json.String(record.strand)),
    #("operation", json.String(ids.op_id_to_string(record.operation))),
    #("step", json.String(record.step)),
    #("deadline_ms", json.Int(record.deadline_ms)),
    #("source", json.String(record.source)),
    #("seam", json.String(record.seam)),
    #("phase", json.String(phase)),
    #("result", result),
  ])
}

/// Decodes all authority-bearing fields without guessing absent values.
///
/// ## Examples
///
/// ```gleam
/// assert async_execution.decode(json.Null) |> result.is_error
/// ```
pub fn decode(
  value: JsonValue,
) -> Result(Execution, corruption.CorruptionReport) {
  decode_record(value)
  |> result.map_error(fn(reason) {
    corruption.report(
      at: "runtime/async_execution.decode",
      on: "record",
      expected: reason,
      context: "invalid async execution record",
    )
  })
}

fn decode_record(value: JsonValue) -> Result(Execution, String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("an object")
  })
  use version <- result.try(field(fields, "version"))
  use Nil <- result.try(case version {
    json.Int(1) -> Ok(Nil)
    _ -> Error("version 1")
  })
  use id <- result.try(text(fields, "id"))
  use Nil <- result.try(case valid_id(id) {
    True -> Ok(Nil)
    False -> Error("a bounded execution identity")
  })
  use strand <- result.try(text(fields, "strand"))
  use operation <- result.try(text(fields, "operation"))
  use operation <- result.try(
    ids.parse_op_id(operation) |> result.replace_error("an operation id"),
  )
  use step <- result.try(text(fields, "step"))
  use Nil <- result.try(case step == "async/" <> id {
    True -> Ok(Nil)
    False -> Error("the execution's own broker step")
  })
  use deadline <- result.try(field(fields, "deadline_ms"))
  use deadline_ms <- result.try(case deadline {
    json.Int(at) if at > 0 -> Ok(at)
    _ -> Error("a positive absolute deadline")
  })
  use source <- result.try(text(fields, "source"))
  use seam <- result.try(text(fields, "seam"))
  use Nil <- result.try(case seam {
    "workspace" | "orchestration" -> Ok(Nil)
    _ -> Error("a known execution seam")
  })
  use phase <- result.try(text(fields, "phase"))
  use payload <- result.try(field(fields, "result"))
  use phase <- result.try(case phase, payload {
    "starting", json.Null -> Ok(Starting)
    "running", json.Null -> Ok(Running)
    "draining", json.Null -> Ok(Draining)
    "finished", value -> Ok(Finished(value))
    "lost", json.String(reason) -> Ok(Lost(reason))
    _, _ -> Error("a complete execution phase")
  })
  Ok(Execution(
    id:,
    strand:,
    operation:,
    step:,
    deadline_ms:,
    source:,
    seam:,
    phase:,
  ))
}

fn field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(JsonValue, String) {
  list.key_find(fields, name) |> result.replace_error("field " <> name)
}

fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  use value <- result.try(field(fields, name))
  case value {
    json.String(text) -> Ok(text)
    _ -> Error("text field " <> name)
  }
}

/// Durable fence shared by operator abort and owned-child reaping.
///
/// ## Examples
///
/// ```gleam
/// // async_execution.abort_key(operation)
/// ```
pub fn abort_key(operation: ids.OpId) -> String {
  prefix <> "aborted/" <> ids.op_id_to_string(operation)
}
